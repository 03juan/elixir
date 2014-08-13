defmodule Mix.Tasks.Local.Rebar do
  use Mix.Task

  import Mix.Generator, only: [create_file: 3]

  @rebar_url "http://s3.hex.pm/rebar"
  @shortdoc  "Install rebar locally"

  @moduledoc """
  Fetch a copy of rebar from the given path or url. It defaults to a
  rebar copy that ships with Elixir source if available or fetches it
  from #{@rebar_url}.

  The local copy is stored in your MIX_HOME (defaults to ~/.mix).
  This version of rebar will be used as required by `mix deps.compile`.

  ## Command line options

    * `--force` - forces installation without a shell prompt; primarily
      intended for automation in build systems like make
  """
  @spec run(OptionParser.argv) :: true
  def run(argv) do
    {opts, argv, _} = OptionParser.parse(argv, switches: [force: :boolean])

    path = case argv do
      []       -> @rebar_url
      [path|_] -> path
    end
    do_install(path, opts)
  end

  defp do_install(path, opts) do
    rebar = Mix.Utils.read_path!(path)
    local_rebar_path = Mix.Rebar.local_rebar_path
    File.mkdir_p! Path.dirname(local_rebar_path)
    create_file local_rebar_path, rebar, opts
    :ok = :file.change_mode local_rebar_path, 0o755
    true
  end
end
