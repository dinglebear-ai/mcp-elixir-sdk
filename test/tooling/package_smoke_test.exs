defmodule MCP.Tooling.PackageSmokeTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/package_smoke.exs", __DIR__)
  @dependency ~s|{:plexus, git: "https://github.com/dinglebear-ai/mcp-elixir-sdk.git", ref: "86ce543498ee8cd1b62fe66e15f7380e2feb07bb"}|

  test "consumer smoke rejects mutable or invalid coordinates before running Mix" do
    for dependency <- [
          String.replace(@dependency, "86ce543498ee8cd1b62fe66e15f7380e2feb07bb", "main"),
          String.replace(@dependency, ":plexus", ":mcp_elixir_sdk"),
          String.replace(@dependency, "https://", "http://"),
          String.replace(@dependency, "github.com", "example.com")
        ] do
      assert_rejected!("## Installation\n\n```elixir\n#{dependency}\n```\n")
    end
  end

  test "consumer smoke does not accept a coordinate from a different section" do
    assert_rejected!("## Installation\nNo coordinate.\n\n## Examples\n#{@dependency}\n")
    assert_rejected!("## Examples\n#{@dependency}\n")
  end

  defp assert_rejected!(readme) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    fixture = Path.join(System.tmp_dir!(), "plexus-readme-test-#{suffix}")
    File.mkdir_p!(fixture)
    on_exit(fn -> File.rm_rf!(fixture) end)
    File.write!(Path.join(fixture, "README.md"), readme)

    assert {output, 1} =
             System.cmd("elixir", [@script, "--readme-only"],
               cd: fixture,
               env: [{"ERL_FLAGS", "+S 2:2 +A 2"}],
               stderr_to_stdout: true
             )

    assert output =~
             "README must advertise a :plexus Git dependency pinned to an immutable commit"

    refute output =~ "==> (package) mix"
  end
end
