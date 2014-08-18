Code.require_file "test_helper.exs", __DIR__

defmodule GenEventTest do
  use ExUnit.Case, async: true

  defmodule ReplyHandler do
    use GenEvent

    def init(:raise) do
      raise "oops"
    end

    def init({:throw, process}) do
      {:ok, process}
    end

    def init({:raise, _}) do
      raise "oops"
    end

    def init({:swap, {:error, :module_not_found}}) do
      {:error, :module_not_found_on_swap}
    end

    def init({:swap, parent}) when is_pid(parent) do
      send parent, :swapped
      {:ok, parent}
    end

    def init({:custom, return}) do
      return
    end

    def init({parent, :hibernate}) do
      {:ok, parent, :hibernate}
    end

    def init({parent, trap}) when is_pid(parent) and is_boolean(trap) do
      Process.flag(:trap_exit, trap)
      {:ok, parent}
    end

    def handle_event(:raise, _parent) do
      raise "oops"
    end

    def handle_event(:hibernate, parent) do
      {:ok, parent, :hibernate}
    end

    def handle_event({:custom, reply}, _parent) do
      reply
    end

    def handle_event(event, parent) do
      send parent, {:event, event}
      {:ok, parent}
    end

    def handle_call(:raise, _parent) do
      raise "oops"
    end

    def handle_call(:hibernate, parent) do
      {:ok, :ok, parent, :hibernate}
    end

    def handle_call({:custom, reply}, _parent) do
      reply
    end

    def handle_call(event, parent) do
      send parent, {:call, event}
      {:ok, :ok, parent}
    end

    def handle_info(:hibernate, parent) do
      {:ok, parent, :hibernate}
    end

    def handle_info(event, parent) do
      send parent, {:info, event}
      {:ok, parent}
    end

    def terminate(:raise, _parent) do
      raise "oops"
    end

    def terminate(:swapped, parent) do
      send parent, {:terminate, :swapped}
      parent
    end

    def terminate(arg, parent) do
      send parent, {:terminate, arg}
    end
  end

  defmodule DefaultHandler do
    use GenEvent
  end

  defmodule Via do
    def register_name(name, pid) do
      Process.register(pid, name)
      :yes
    end

    def whereis_name(name) do
      Process.whereis(name) || :undefined
    end
  end

  @receive_timeout 1000

  test "start/1" do
    assert {:ok, pid} = GenEvent.start()
    assert GenEvent.which_handlers(pid) == []
    assert GenEvent.stop(pid) == :ok

    assert {:ok, pid} = GenEvent.start(name: :my_gen_event_name)
    assert GenEvent.which_handlers(:my_gen_event_name) == []
    assert GenEvent.which_handlers(pid) == []
    assert GenEvent.stop(:my_gen_event_name) == :ok
  end

  test "start_link/1" do
    assert {:ok, pid} = GenEvent.start_link()
    assert GenEvent.which_handlers(pid) == []
    assert GenEvent.stop(pid) == :ok

    assert {:ok, pid} = GenEvent.start_link(name: :my_gen_event_name)
    assert GenEvent.which_handlers(:my_gen_event_name) == []
    assert GenEvent.which_handlers(pid) == []
    assert GenEvent.stop(:my_gen_event_name) == :ok

    assert {:ok, pid} = GenEvent.start_link(name: {:global, :my_gen_event_name})
    assert GenEvent.which_handlers({:global, :my_gen_event_name}) == []
    assert GenEvent.which_handlers(pid) == []
    assert GenEvent.stop({:global, :my_gen_event_name}) == :ok

    assert {:ok, pid} = GenEvent.start_link(name: {:via, Via, :my_gen_event_name})
    assert GenEvent.which_handlers({:via, Via, :my_gen_event_name}) == []
    assert GenEvent.which_handlers(pid) == []
    assert GenEvent.stop({:via, Via, :my_gen_event_name}) == :ok

    assert {:ok, pid} = GenEvent.start_link(name: :my_gen_event_name)
    assert GenEvent.start_link(name: :my_gen_event_name) ==
           {:error, {:already_started, pid}}
  end

  test "handles exit signals" do
    Process.flag(:trap_exit, true)

    # Terminates on signal from parent when not trapping exits
    {:ok, pid} = GenEvent.start_link()
    :ok = GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    Process.exit(pid, :shutdown)
    assert_receive {:EXIT, ^pid, :shutdown}
    refute_received {:terminate, _}

    # Terminates on signal from parent when trapping exits
    {:ok, pid} = GenEvent.start_link()
    :ok = GenEvent.add_handler(pid, ReplyHandler, {self(), true})
    Process.exit(pid, :shutdown)
    assert_receive {:EXIT, ^pid, :shutdown}
    assert_receive {:terminate, :stop}

    # Terminates on signal not from parent when not trapping exits
    {:ok, pid} = GenEvent.start_link()
    :ok = GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    spawn fn -> Process.exit(pid, :shutdown) end
    assert_receive {:EXIT, ^pid, :shutdown}
    refute_received {:terminate, _}

    # Does not terminate on signal not from parent when trapping exits
    {:ok, pid} = GenEvent.start_link()
    :ok = GenEvent.add_handler(pid, ReplyHandler, {self(), true})
    terminator = spawn fn -> Process.exit(pid, :shutdown) end
    assert_receive {:info, {:EXIT, ^terminator, :shutdown}}
    refute_received {:terminate, _}
  end

  defp hibernating?(pid) do
    Process.info(pid, :current_function) ==
      {:current_function,{:erlang,:hibernate,3}}
  end

  defp wait_until(fun, counter \\ 0) do
    cond do
      counter > 100 ->
        flunk "Waited for 1s, but #{inspect fun} never returned true"
      fun.() ->
        true
      true ->
        receive after: (10 -> wait_until(fun, counter + 1))
    end
  end

  defp wake_up(pid) do
    send pid, :wake
    assert_receive {:info, :wake}
  end

  test "hibernates" do
    {:ok, pid} = GenEvent.start()
    :ok = GenEvent.add_handler(pid, ReplyHandler, {self(), :hibernate})
    wait_until fn -> hibernating?(pid) end

    wake_up(pid)
    refute hibernating?(pid)

    :ok = GenEvent.call(pid, ReplyHandler, :hibernate)
    wait_until fn -> hibernating?(pid) end

    wake_up(pid)
    :ok = GenEvent.sync_notify(pid, :hibernate)
    wait_until fn -> hibernating?(pid) end

    GenEvent.stop(pid)
  end

  test "add_handler/4" do
    {:ok, pid} = GenEvent.start()

    assert GenEvent.add_handler(pid, ReplyHandler, {:custom, {:error, :my_error}}) ==
           {:error, :my_error}
    assert GenEvent.add_handler(pid, ReplyHandler, {:custom, :oops}) ==
           {:error, {:bad_return_value, :oops}}

    assert {:error, {%RuntimeError{}, _}} =
           GenEvent.add_handler(pid, ReplyHandler, :raise)

    assert GenEvent.add_handler(pid, ReplyHandler, {:throw, self()}) == :ok
    assert GenEvent.which_handlers(pid) == [ReplyHandler]
    assert GenEvent.add_handler(pid, ReplyHandler, {:throw, self()}) == {:error, :already_added}

    assert GenEvent.add_handler(pid, {ReplyHandler, self()}, {self(), false}) == :ok
    assert GenEvent.which_handlers(pid) == [{ReplyHandler, self()}, ReplyHandler]
  end

  test "add_handler/4 with monitor" do
    {:ok, pid} = GenEvent.start()
    parent = self()

    {mon_pid, mon_ref} = spawn_monitor(fn ->
      assert GenEvent.add_handler(pid, ReplyHandler, {self(), false}, monitor: true) == :ok
      send parent, :ok
      receive after: (:infinity -> :ok)
    end)

    assert_receive :ok
    assert GenEvent.add_handler(pid, {ReplyHandler, self()}, {self(), false}) == :ok
    assert GenEvent.which_handlers(pid) == [{ReplyHandler, self()}, ReplyHandler]

    # A regular monitor message is passed forward
    send pid, {:DOWN, make_ref(), :process, self(), :oops}
    assert_receive {:info, {:DOWN, _, :process, _, :oops}}

    # Killing the monitor though is not passed forward
    Process.exit(mon_pid, :oops)
    assert_receive {:DOWN, ^mon_ref, :process, ^mon_pid, :oops}
    refute_received {:info, {:DOWN, _, :process, _, :oops}}
    assert GenEvent.which_handlers(pid) == [{ReplyHandler, self()}]
  end

  test "add_handler/4 with notifications" do
    {:ok, pid} = GenEvent.start()
    self = self()

    GenEvent.add_handler(pid, ReplyHandler, {self(), false}, monitor: true)
    GenEvent.remove_handler(pid, ReplyHandler, :ok)
    assert_receive {:gen_event_EXIT, ReplyHandler, :normal}

    GenEvent.add_handler(pid, ReplyHandler, {self(), false}, monitor: true)
    GenEvent.swap_handler(pid, ReplyHandler, :swapped, ReplyHandler, :swap)
    assert_receive {:gen_event_EXIT, ReplyHandler, {:swapped, ReplyHandler, nil}}

    GenEvent.swap_handler(pid, ReplyHandler, :swapped, ReplyHandler, :swap, monitor: true)
    GenEvent.swap_handler(pid, ReplyHandler, :swapped, ReplyHandler, :swap, monitor: true)
    assert_receive {:gen_event_EXIT, ReplyHandler, {:swapped, ReplyHandler, ^self}}

    GenEvent.stop(pid)
    assert_receive {:gen_event_EXIT, ReplyHandler, :shutdown}
  end

  test "remove_handler/3" do
    {:ok, pid} = GenEvent.start()

    GenEvent.add_handler(pid, ReplyHandler, {self(), false}, monitor: true)

    assert GenEvent.remove_handler(pid, {ReplyHandler, self()}, :ok) ==
           {:error, :module_not_found}
    assert GenEvent.remove_handler(pid, ReplyHandler, :ok) ==
           {:terminate, :ok}
    assert_receive {:terminate, :ok}

    GenEvent.add_handler(pid, {ReplyHandler, self()}, {self(), false}, monitor: true)

    assert GenEvent.remove_handler(pid, ReplyHandler, :ok) ==
           {:error, :module_not_found}
    assert {:error, {%RuntimeError{}, _}} =
           GenEvent.remove_handler(pid, {ReplyHandler, self()}, :raise)

    assert GenEvent.which_handlers(pid) == []
  end

  test "swap_handler/6" do
    {:ok, pid} = GenEvent.start()

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert GenEvent.swap_handler(pid, ReplyHandler, :swapped,
                                 {ReplyHandler, self()}, :swap) == :ok
    assert_receive {:terminate, :swapped}
    assert_receive :swapped

    assert GenEvent.add_handler(pid, ReplyHandler, {self(), false}) == :ok
    assert GenEvent.swap_handler(pid, ReplyHandler, :swapped,
                                 {ReplyHandler, self()}, :swap) == {:error, :already_added}
    assert GenEvent.which_handlers(pid) == [{ReplyHandler, self()}]

    assert GenEvent.remove_handler(pid, {ReplyHandler, self()}, :remove_handler) ==
           {:terminate, :remove_handler}

    # The handler is initialized even when the module does not exist
    # on swap. However, in this case, we are returning an error on init.
    assert GenEvent.swap_handler(pid, ReplyHandler, :swapped, ReplyHandler, :swap) ==
           {:error, :module_not_found_on_swap}
  end

  test "notify/2" do
    {:ok, pid} = GenEvent.start()
    GenEvent.add_handler(pid, ReplyHandler, {self(), false})

    assert GenEvent.notify(pid, :hello) == :ok
    assert_receive {:event, :hello}

    msg = {:custom, {:swap_handler, :swapped, self(), ReplyHandler, :swap}}
    assert GenEvent.notify(pid, msg) == :ok
    assert_receive {:terminate, :swapped}
    assert_receive :swapped

    assert GenEvent.notify(pid, {:custom, :remove_handler}) == :ok
    assert_receive {:terminate, :remove_handler}
    assert GenEvent.which_handlers(pid) == []

    Logger.remove_backend(:console)

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert GenEvent.notify(pid, {:custom, :oops}) == :ok
    assert_receive {:terminate, {:error, {:bad_return_value, :oops}}}

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert GenEvent.notify(pid, :raise) == :ok
    assert_receive {:terminate, {:error, {%RuntimeError{}, _}}}
  after
    Logger.add_backend(:console, flush: true)
  end

  test "notify/2 with bad args" do
    assert GenEvent.notify({:global, :foo}, :bar) == :ok
    assert GenEvent.notify({:foo, :bar}, :bar) == :ok
    assert GenEvent.notify(self, :bar) == :ok

    assert_raise ArgumentError, fn ->
      GenEvent.notify(:foo, :bar)
    end
  end

  test "ack_notify/2" do
    {:ok, pid} = GenEvent.start()
    GenEvent.add_handler(pid, ReplyHandler, {self(), false})

    assert GenEvent.ack_notify(pid, :hello) == :ok
    assert_receive {:event, :hello}

    msg = {:custom, {:swap_handler, :swapped, self(), ReplyHandler, :swap}}
    assert GenEvent.ack_notify(pid, msg) == :ok
    assert_receive {:terminate, :swapped}
    assert_receive :swapped

    assert GenEvent.ack_notify(pid, {:custom, :remove_handler}) == :ok
    assert_receive {:terminate, :remove_handler}
    assert GenEvent.which_handlers(pid) == []

    Logger.remove_backend(:console)

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert GenEvent.ack_notify(pid, {:custom, :oops}) == :ok
    assert_receive {:terminate, {:error, {:bad_return_value, :oops}}}

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert GenEvent.ack_notify(pid, :raise) == :ok
    assert_receive {:terminate, {:error, {%RuntimeError{}, _}}}
  after
    Logger.add_backend(:console, flush: true)
  end

  test "sync_notify/2" do
    {:ok, pid} = GenEvent.start()
    GenEvent.add_handler(pid, ReplyHandler, {self(), false})

    assert GenEvent.sync_notify(pid, :hello) == :ok
    assert_received {:event, :hello}

    msg = {:custom, {:swap_handler, :swapped, self(), ReplyHandler, :swap}}
    assert GenEvent.sync_notify(pid, msg) == :ok
    assert_received {:terminate, :swapped}
    assert_received :swapped

    assert GenEvent.sync_notify(pid, {:custom, :remove_handler}) == :ok
    assert_received {:terminate, :remove_handler}
    assert GenEvent.which_handlers(pid) == []

    Logger.remove_backend(:console)

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert GenEvent.sync_notify(pid, {:custom, :oops}) == :ok
    assert_received {:terminate, {:error, {:bad_return_value, :oops}}}

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert GenEvent.sync_notify(pid, :raise) == :ok
    assert_received {:terminate, {:error, {%RuntimeError{}, _}}}
  after
    Logger.add_backend(:console, flush: true)
  end

  test "call/3" do
    {:ok, pid} = GenEvent.start()
    GenEvent.add_handler(pid, ReplyHandler, {self(), false})

    assert GenEvent.call(pid, ReplyHandler, :hello) == :ok
    assert_receive {:call, :hello}

    msg = {:custom, {:swap_handler, :ok, :swapped, self(), ReplyHandler, :swap}}
    assert GenEvent.call(pid, ReplyHandler, msg) == :ok
    assert_receive {:terminate, :swapped}
    assert_receive :swapped

    assert GenEvent.call(pid, ReplyHandler, {:custom, {:remove_handler, :ok}}) == :ok
    assert_receive {:terminate, :remove_handler}
    assert GenEvent.which_handlers(pid) == []

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    msg = {:custom, {:swap_handler, :ok, :swapped, self(), ReplyHandler, :raise}}
    assert GenEvent.call(pid, ReplyHandler, msg) == :ok
    assert GenEvent.which_handlers(pid) == []

    Logger.remove_backend(:console)

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    GenEvent.add_handler(pid, {ReplyHandler, self}, {self(), false})

    msg = {:custom, {:swap_handler, :ok, :swapped, self(), ReplyHandler, :raise}}
    assert GenEvent.call(pid, {ReplyHandler, self()}, msg) == :ok
    assert GenEvent.which_handlers(pid) == [ReplyHandler]

    assert {:error, {:bad_return_value, :oops}} =
           GenEvent.call(pid, ReplyHandler, {:custom, :oops})
    assert_receive {:terminate, {:error, {:bad_return_value, :oops}}}
    assert GenEvent.which_handlers(pid) == []

    GenEvent.add_handler(pid, ReplyHandler, {self(), false})
    assert {:error, {%RuntimeError{}, _}} = GenEvent.call(pid, ReplyHandler, :raise)
    assert_receive {:terminate, {:error, {%RuntimeError{}, _}}}
    assert GenEvent.which_handlers(pid) == []
  after
    Logger.add_backend(:console, flush: true)
  end

  test "call/2 with bad args" do
    Logger.remove_backend(:console)
    {:ok, pid} = GenEvent.start_link()

    assert GenEvent.add_handler(pid, DefaultHandler, []) == :ok
    assert GenEvent.call(pid, UnknownHandler, :messages) ==
            {:error, :module_not_found}
    assert GenEvent.call(pid, DefaultHandler, :whatever) ==
            {:error, {:bad_call, :whatever}}
    assert GenEvent.which_handlers(pid) == []
    assert GenEvent.stop(pid) == :ok
  after
    Logger.add_backend(:console, flush: true)
  end
end
