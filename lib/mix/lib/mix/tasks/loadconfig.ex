defmodule Mix.Tasks.Loadconfig do
  use Mix.Task

  @shortdoc "Loads and persists the given configuration"

  @moduledoc """
  Loads and persists the given configuration.

  In case no configuration file is given, it
  loads the project one at "config/config.exs".

  This task is automatically reenabled, so it
  can be called multiple times to load different
  configs.
  """
  def run(args) do
    cond do
      file = Enum.at(args, 0) ->
        load file
      File.regular?("config/config.exs") ->
        load "config/config.exs"
      true ->
        :ok
    end

    Mix.Task.reenable "loadconfig"
  end

  defp load(file) do
    Mix.Config.persist Mix.Config.read!(file)
    :ok
  end
end
