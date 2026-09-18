defmodule MCP.Tooling.ReqCompatTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/select_req_compat.exs", __DIR__)
  @constraint ~s({:req, ">= 0.6.1 and < 0.8.0"})

  test "selects both exact Req boundaries without making the dependency optional" do
    original = "[#{@constraint}, {:bandit, \"~> 1.12.5\", optional: true}]\n"

    for version <- ["0.6.1", "0.7.2"] do
      fixture = fixture!(original)
      assert {_output, 0} = select(fixture, version)
      expected = String.replace(original, @constraint, ~s({:req, "== #{version}"}))
      assert File.read!(Path.join(fixture, "mix.exs")) == expected
    end
  end

  test "unsupported versions fail without changing the dependency file" do
    fixture = fixture!(@constraint)
    assert {output, 1} = select(fixture, "0.8.0")
    assert output =~ "expected one supported Req version"
    assert File.read!(Path.join(fixture, "mix.exs")) == @constraint
  end

  test "unexpected constraints fail without modifying the source" do
    original = ~s({:req, "~> 0.7"})
    fixture = fixture!(original)
    assert {output, 1} = select(fixture, "0.6.1")
    assert output =~ "expected Req compatibility constraint was not found"
    assert File.read!(Path.join(fixture, "mix.exs")) == original
  end

  defp fixture!(source) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "plexus-req-compat-test-#{suffix}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "mix.exs"), source)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp select(directory, version) do
    System.cmd("elixir", [@script, version],
      cd: directory,
      env: [{"ERL_FLAGS", "+S 2:2 +A 2"}],
      stderr_to_stdout: true
    )
  end
end
