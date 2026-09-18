defmodule MCP.Version do
  @moduledoc false

  @version to_string(Mix.Project.config()[:version])

  def current, do: @version
end
