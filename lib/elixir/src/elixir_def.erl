% Holds the logic responsible for function definitions (def(p) and defmacro(p)).
-module(elixir_def).
-export([table/1, clauses_table/1, setup/1,
  cleanup/1, reset_last/1, lookup_definition/2,
  delete_definition/2, store_definition/6, unwrap_definitions/1,
  store_each/8, format_error/1]).
-include("elixir.hrl").

-define(attr, '__def_table').
-define(clauses_attr, '__clauses_table').

%% Table management functions. Called internally.

table(Module) ->
  ets:lookup_element(Module, ?attr, 2).

clauses_table(Module) ->
  ets:lookup_element(Module, ?clauses_attr, 2).

setup(Module) ->
  ets:insert(Module, {?attr, ets:new(Module, [set, public])}),
  ets:insert(Module, {?clauses_attr, ets:new(Module, [bag, public])}),
  reset_last(Module),
  ok.

cleanup(Module) ->
  ets:delete(table(Module)),
  ets:delete(clauses_table(Module)).

%% Reset the last item. Useful when evaling code.
reset_last(Module) ->
  ets:insert(table(Module), {last, []}).

%% Looks up a definition from the database.
lookup_definition(Module, Tuple) ->
  case ets:lookup(table(Module), Tuple) of
    [Result] ->
      CTable = clauses_table(Module),
      {Result, [Clause || {_, Clause} <- ets:lookup(CTable, Tuple)]};
    _ ->
      false
  end.

delete_definition(Module, Tuple) ->
  ets:delete(table(Module), Tuple),
  ets:delete(clauses_table(Module), Tuple).

% Invoked by the wrap definition with the function abstract tree.
% Each function is then added to the function table.

store_definition(Line, Kind, CheckClauses, Call, Body, Pos) ->
  E = (elixir_locals:get_cached_env(Pos))#{line := Line},
  {NameAndArgs, Guards} = elixir_clauses:extract_guards(Call),

  {Name, Args} = case NameAndArgs of
    {N, _, A} when is_atom(N), is_atom(A) -> {N, []};
    {N, _, A} when is_atom(N), is_list(A) -> {N, A};
    _ -> elixir_errors:form_error(Line, ?m(E, file), ?MODULE, {invalid_def, Kind, NameAndArgs})
  end,

  %% Now that we have verified the call format,
  %% extract meta information like file and context.
  {_, Meta, _} = Call,
  DoCheckClauses = (not lists:keymember(context, 1, Meta)) andalso (CheckClauses),

  %% Check if there is a file information in the definition.
  %% If so, we assume this come from another source and we need
  %% to linify taking into account keep line numbers.
  {File, Key}  = case lists:keyfind(file, 1, Meta) of
    {file, Bin} when is_binary(Bin) -> {Bin, keep};
    _ -> {nil, line}
  end,

  LinifyArgs   = elixir_quote:linify(Line, Key, Args),
  LinifyGuards = elixir_quote:linify(Line, Key, Guards),
  LinifyBody   = elixir_quote:linify(Line, Key, Body),

  assert_no_aliases_name(Line, Name, Args, E),
  store_definition(Line, Kind, DoCheckClauses, Name,
                   LinifyArgs, LinifyGuards, LinifyBody, File, E).

store_definition(Line, Kind, CheckClauses, Name, Args, Guards, Body, MetaFile, #{module := Module} = ER) ->
  Arity = length(Args),
  Tuple = {Name, Arity},
  E = ER#{function := Tuple},
  elixir_locals:record_definition(Tuple, Kind, Module),

  Location = retrieve_location(Line, MetaFile, Module),
  {Function, Defaults, Super} = translate_definition(Kind, Line, Module, Name, Args, Guards, Body, E),

  DefaultsLength = length(Defaults),
  elixir_locals:record_defaults(Tuple, Kind, Module, DefaultsLength),

  File   = ?m(E, file),
  Table  = table(Module),
  CTable = clauses_table(Module),

  compile_super(Module, Super, E),
  check_previous_defaults(Table, Line, Name, Arity, Kind, DefaultsLength, E),

  store_each(CheckClauses, Kind, File, Location,
    Table, CTable, DefaultsLength, Function),
  [store_each(false, Kind, File, Location, Table, CTable, 0,
    default_function_for(Kind, Name, Default)) || Default <- Defaults],

  make_struct_available(Kind, Module, Name, Args),
  {Name, Arity}.

%% @on_definition

run_on_definition_callbacks(Kind, Line, Module, Name, Args, Guards, Expr, E) ->
  case elixir_compiler:get_opt(internal) of
    true ->
      ok;
    _ ->
      Env = elixir_env:linify({Line, E}),
      Callbacks = 'Elixir.Module':get_attribute(Module, on_definition),
      [Mod:Fun(Env, Kind, Name, Args, Guards, Expr) || {Mod, Fun} <- Callbacks]
  end.

make_struct_available(def, Module, '__struct__', []) ->
  case erlang:get(elixir_compiler_pid) of
    undefined -> ok;
    Pid -> Pid ! {struct_available, Module}
  end;
make_struct_available(_, _, _, _) ->
  ok.

%% Retrieve location from meta file or @file, otherwise nil

retrieve_location(Line, File, Module) ->
  case get_location_attribute(Module) of
    nil when not is_binary(File) ->
      nil;
    nil ->
      {normalize_location(File), Line};
    X when is_binary(X) ->
      'Elixir.Module':delete_attribute(Module, file),
      {normalize_location(X), 0};
    {X, L} when is_binary(X) andalso is_integer(L) ->
      'Elixir.Module':delete_attribute(Module, file),
      {normalize_location(X), L}
  end.

get_location_attribute(Module) ->
  case elixir_compiler:get_opt(internal) of
    true  -> nil;
    false -> 'Elixir.Module':get_attribute(Module, file)
  end.

normalize_location(X) ->
  elixir_utils:characters_to_list(elixir_utils:relative_to_cwd(X)).

%% Compile super

compile_super(Module, true, #{function := Function}) ->
  elixir_def_overridable:store(Module, Function, true);
compile_super(_Module, _, _E) -> ok.

%% Translate the given call and expression given
%% and then store it in memory.

translate_definition(Kind, Line, Module, Name, Args, Guards, Body, E) when is_integer(Line) ->
  Arity = length(Args),

  {EArgs, EGuards, EBody, _} = elixir_exp_clauses:def(fun elixir_def_defaults:expand/2,
                                   Args, Guards, expr_from_body(Line, Body), E),

  Body == nil andalso check_args_for_bodyless_clause(Line, EArgs, E),

  S = elixir_env:env_to_scope(E),
  {Unpacked, Defaults} = elixir_def_defaults:unpack(Kind, Name, EArgs, S),
  {Clauses, Super} = translate_clause(Body, Line, Kind, Unpacked, EGuards, EBody, S),

  run_on_definition_callbacks(Kind, Line, Module, Name, EArgs, EGuards, EBody, E),
  Function = {function, Line, Name, Arity, Clauses},
  {Function, Defaults, Super}.

translate_clause(nil, _Line, _Kind, _Args, [], _Body, _S) ->
  {[], false};
translate_clause(nil, Line, Kind, _Args, _Guards, _Body, #elixir_scope{file=File}) ->
  elixir_errors:form_error(Line, File, ?MODULE, {missing_do, Kind});
translate_clause(_, Line, Kind, Args, Guards, Body, S) ->
  {TClause, TS} = elixir_clauses:clause(Line,
    fun elixir_translator:translate_args/2, Args, Body, Guards, true, S),

  FClause = case is_macro(Kind) of
    true ->
      FArgs = {var, Line, '_@CALLER'},
      MClause = setelement(3, TClause, [FArgs|element(3, TClause)]),

      case TS#elixir_scope.caller of
        true  ->
          FBody = {'match', Line,
            {'var', Line, '__CALLER__'},
            elixir_utils:erl_call(Line, elixir_env, linify, [{var, Line, '_@CALLER'}])
          },
          setelement(5, MClause, [FBody|element(5, TClause)]);
        false ->
          MClause
      end;
    false ->
      TClause
  end,

  {[FClause], TS#elixir_scope.super}.

expr_from_body(_Line, nil)          -> nil;
expr_from_body(_Line, [{do, Expr}]) -> Expr;
expr_from_body(Line, Else)          -> {'try', [{line,Line}], [Else]}.

is_macro(defmacro)  -> true;
is_macro(defmacrop) -> true;
is_macro(_)         -> false.

% Unwrap the functions stored in the functions table.
% It returns a list of all functions to be exported, plus the macros,
% and the body of all functions.
unwrap_definitions(Module) ->
  Table = table(Module),
  CTable = clauses_table(Module),
  ets:delete(Table, last),
  unwrap_definition(ets:tab2list(Table), CTable, [], [], [], [], [], [], []).

unwrap_definition([Fun|T], CTable, All, Exports, Private, Def, Defmacro, Functions, Tail) ->
  Tuple   = element(1, Fun),
  Clauses = [Clause || {_, Clause} <- ets:lookup(CTable, Tuple)],

  {NewFun, NewExports, NewPrivate, NewDef, NewDefmacro} =
    case Clauses of
      [] -> {false, Exports, Private, Def, Defmacro};
      _  -> unwrap_definition(element(2, Fun), Tuple, Fun, Exports, Private, Def, Defmacro)
    end,

  {NewFunctions, NewTail} = case NewFun of
    false ->
      NewAll = All,
      {Functions, Tail};
    _ ->
      NewAll = [Tuple|All],
      function_for_stored_definition(NewFun, Clauses, Functions, Tail)
  end,

  unwrap_definition(T, CTable, NewAll, NewExports, NewPrivate,
    NewDef, NewDefmacro, NewFunctions, NewTail);
unwrap_definition([], _CTable, All, Exports, Private, Def, Defmacro, Functions, Tail) ->
  {All, Exports, Private, ordsets:from_list(Def),
    ordsets:from_list(Defmacro), lists:reverse(Tail ++ Functions)}.

unwrap_definition(def, Tuple, Fun, Exports, Private, Def, Defmacro) ->
  {Fun, [Tuple|Exports], Private, [Tuple|Def], Defmacro};
unwrap_definition(defmacro, {Name, Arity} = Tuple, Fun, Exports, Private, Def, Defmacro) ->
  Macro = {elixir_utils:macro_name(Name), Arity + 1},
  {setelement(1, Fun, Macro), [Macro|Exports], Private, Def, [Tuple|Defmacro]};
unwrap_definition(defp, Tuple, Fun, Exports, Private, Def, Defmacro) ->
  {_, _, Line, _, Check, _, {Defaults, _, _}} = Fun,
  Info = {Tuple, defp, Line, Check, Defaults},
  {Fun, Exports, [Info|Private], Def, Defmacro};
unwrap_definition(defmacrop, Tuple, Fun, Exports, Private, Def, Defmacro) ->
  {_, _, Line, _, Check, _, {Defaults, _, _}} = Fun,
  Info  = {Tuple, defmacrop, Line, Check, Defaults},
  {false, Exports, [Info|Private], Def, Defmacro}.

%% Helpers

function_for_stored_definition({{Name,Arity}, _, Line, _, _, nil, _}, Clauses, Functions, Tail) ->
  {[{function, Line, Name, Arity, Clauses}|Functions], Tail};

function_for_stored_definition({{Name,Arity}, _, Line, _, _, Location, _}, Clauses, Functions, Tail) ->
  {Functions, [
    {function, Line, Name, Arity, Clauses},
    {attribute, Line, file, Location} | Tail
  ]}.

default_function_for(Kind, Name, {clause, Line, Args, _Guards, _Exprs} = Clause)
    when Kind == defmacro; Kind == defmacrop ->
  {function, Line, Name, length(Args) - 1, [Clause]};

default_function_for(_, Name, {clause, Line, Args, _Guards, _Exprs} = Clause) ->
  {function, Line, Name, length(Args), [Clause]}.

%% Store each definition in the table.
%% This function also checks and emit warnings in case
%% the kind, of the visibility of the function changes.

store_each(Check, Kind, File, Location, Table, CTable, Defaults, {function, Line, Name, Arity, Clauses}) ->
  Tuple = {Name, Arity},
  HasBody = Clauses =/= [],
  case ets:lookup(Table, Tuple) of
    [{Tuple, StoredKind, StoredLine, StoredFile, StoredCheck, StoredLocation, {StoredDefaults, LastHasBody, LastDefaults}}] ->
      FinalLine = StoredLine,
      FinalLocation = StoredLocation,
      FinalDefaults = {max(Defaults, StoredDefaults), HasBody, Defaults},
      check_valid_kind(Line, File, Name, Arity, Kind, StoredKind),
      (Check and StoredCheck) andalso
        check_valid_clause(Line, File, Name, Arity, Kind, Table, StoredLine, StoredFile),
      check_valid_defaults(Line, File, Name, Arity, Kind, Defaults, LastDefaults, LastHasBody);
    [] ->
      FinalLine = Line,
      FinalLocation = Location,
      FinalDefaults = {Defaults, HasBody, Defaults}
  end,
  Check andalso ets:insert(Table, {last, {Name, Arity}}),
  ets:insert(CTable, [{Tuple, Clause} || Clause <- Clauses ]),
  ets:insert(Table, {Tuple, Kind, FinalLine, File, Check, FinalLocation, FinalDefaults}).

%% Validations

check_valid_kind(_Line, _File, _Name, _Arity, Kind, Kind) -> [];
check_valid_kind(Line, File, Name, Arity, Kind, StoredKind) ->
  elixir_errors:form_error(Line, File, ?MODULE,
    {changed_kind, {Name, Arity, StoredKind, Kind}}).

check_valid_clause(Line, File, Name, Arity, Kind, Table, StoredLine, StoredFile) ->
  case ets:lookup_element(Table, last, 2) of
    {Name,Arity} -> [];
    [] -> [];
    _ ->
      Relative = elixir_utils:relative_to_cwd(StoredFile),
      elixir_errors:handle_file_warning(File, {Line, ?MODULE,
        {ungrouped_clause, {Kind, Name, Arity, StoredLine, Relative}}})
  end.

% Any clause after clause with defaults (body less does not count)
check_valid_defaults(Line, File, Name, Arity, Kind, _, StoredDefaults, true) when StoredDefaults > 0 ->
  elixir_errors:form_error(Line, File, ?MODULE, {clauses_with_defaults, {Kind, Name, Arity}});
% Clause without defaults
check_valid_defaults(_Line, _File, _Name, _Arity, _Kind, 0, _, _) -> [];
% Clause with defaults after clause without defaults
check_valid_defaults(Line, File, Name, Arity, Kind, _, 0, _) ->
  elixir_errors:handle_file_warning(File, {Line, ?MODULE, {out_of_order_defaults, {Kind, Name, Arity}}});
% Clause with defaults after clause with defaults
check_valid_defaults(Line, File, Name, Arity, Kind, _, _, _) ->
  elixir_errors:form_error(Line, File, ?MODULE, {clauses_with_defaults, {Kind, Name, Arity}}).

check_previous_defaults(Table, Line, Name, Arity, Kind, Defaults, E) ->
  Matches = ets:match(Table, {{Name, '$2'}, '$1', '_', '_', '_', '_', {'$3', '_', '_'}}),
  [ begin
      elixir_errors:form_error(Line, ?m(E, file), ?MODULE,
        {defs_with_defaults, Name, {Kind, Arity}, {K, A}})
    end || [K, A, D] <- Matches, A /= Arity, D /= 0, defaults_conflict(A, D, Arity, Defaults)].

defaults_conflict(A, D, Arity, Defaults) ->
  ((Arity >= (A - D)) andalso (Arity < A)) orelse
    ((A >= (Arity - Defaults)) andalso (A < Arity)).

check_args_for_bodyless_clause(Line, Args, E) ->
  [ begin
      elixir_errors:form_error(Line, ?m(E, file), ?MODULE, invalid_args_for_bodyless_clause)
    end || Arg <- Args, invalid_arg(Arg) ].

invalid_arg({Name, _, Kind}) when is_atom(Name), is_atom(Kind) ->
  false;
invalid_arg({'\\\\', _, [{Name, _, Kind}, _]}) when is_atom(Name), is_atom(Kind) ->
  false;
invalid_arg(_) ->
  true.

assert_no_aliases_name(Line, '__aliases__', [Atom], #{file := File}) when is_atom(Atom) ->
  elixir_errors:form_error(Line, File, ?MODULE, {no_alias, Atom});

assert_no_aliases_name(_Meta, _Aliases, _Args, _S) ->
  ok.

%% Format errors

format_error({no_module,{Kind,Name,Arity}}) ->
  io_lib:format("cannot define function outside module, invalid scope for ~ts ~ts/~B", [Kind, Name, Arity]);

format_error({defs_with_defaults, Name, {Kind, Arity}, {K, A}}) when Arity > A ->
  io_lib:format("~ts ~ts/~B defaults conflicts with ~ts ~ts/~B",
    [Kind, Name, Arity, K, Name, A]);

format_error({defs_with_defaults, Name, {Kind, Arity}, {K, A}}) when Arity < A ->
  io_lib:format("~ts ~ts/~B conflicts with defaults from ~ts ~ts/~B",
    [Kind, Name, Arity, K, Name, A]);

format_error({clauses_with_defaults,{Kind,Name,Arity}}) ->
  io_lib:format("~ts ~ts/~B has default values and multiple clauses, "
    "define a function head with the defaults", [Kind, Name, Arity]);

format_error({out_of_order_defaults,{Kind,Name,Arity}}) ->
  io_lib:format("clause with defaults should be the first clause in ~ts ~ts/~B", [Kind, Name, Arity]);

format_error({ungrouped_clause,{Kind,Name,Arity,OrigLine,OrigFile}}) ->
  io_lib:format("clauses for the same ~ts should be grouped together, ~ts ~ts/~B was previously defined (~ts:~B)",
    [Kind, Kind, Name, Arity, OrigFile, OrigLine]);

format_error({changed_kind,{Name,Arity,Previous,Current}}) ->
  io_lib:format("~ts ~ts/~B already defined as ~ts", [Current, Name, Arity, Previous]);

format_error({no_alias, Atom}) ->
  io_lib:format("function names should start with lowercase characters or underscore, invalid name ~ts", [Atom]);

format_error({invalid_def, Kind, NameAndArgs}) ->
  io_lib:format("invalid syntax in ~ts ~ts", [Kind, 'Elixir.Macro':to_string(NameAndArgs)]);

format_error(invalid_args_for_bodyless_clause) ->
  "can use only variables and \\\\ as arguments of bodyless clause";

format_error({missing_do, Kind}) ->
  io_lib:format("missing do keyword in ~ts", [Kind]).
