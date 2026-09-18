defmodule MCP.Tooling.ConformanceLedgersTest do
  use ExUnit.Case, async: false

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/validate_conformance_ledgers.exs")
  @modern "conformance/scenarios.json"
  @legacy "conformance/compatibility-2025-11-25.json"

  setup do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    root = Path.join(System.tmp_dir!(), "mcp-ledger-test-#{suffix}")
    File.mkdir_p!(Path.join(root, "conformance"))
    Enum.each([@modern, @legacy], &File.cp!(Path.join(@root, &1), Path.join(root, &1)))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "valid incomplete evidence reports blocked without failing validation", %{root: root} do
    assert {output, 0} = run(root)
    assert output =~ "conformance ledger validation passed"
    assert output =~ "ledger readiness: blocked"
    assert output =~ "initialize"
    assert output =~ "sse-retry"
  end

  test "release prerequisite fails closed on the real incomplete ledger", %{root: root} do
    assert {output, 1} = run(root, ["--require-ready"])
    assert output =~ "conformance release prerequisite blocked"
    assert output =~ "sse-retry"
  end

  test "JSON readiness is machine-readable and not a false passing release", %{root: root} do
    assert {output, 0} = run(root, ["--json"])
    result = Jason.decode!(output)
    assert result["schemaVersion"] == 1
    assert result["ledgerReadiness"] == "blocked"
    assert result["freshCandidateEvidenceRequired"]
    assert length(result["blockers"]) >= 2
  end

  test "a completed ledger can replace incomplete evidence without editing the validator", %{
    root: root
  } do
    complete_legacy!(root)
    assert {output, 0} = run(root, ["--require-ready"])
    assert output =~ "ledger readiness: ready"
    assert output =~ "fresh candidate evidence is still required"
  end

  test "summary cannot claim a pass while a required scenario is excluded", %{root: root} do
    change(root, @legacy, &put_in(&1, ["client", "status"], "passed"))
    assert_invalid(root, "legacy client status")
  end

  test "every incomplete scenario needs a limitation and a nonblank blocker", %{root: root} do
    change(root, @legacy, &put_in(&1, ["client", "releaseBlocker"], "  \n"))
    assert_invalid(root, "legacy release blocker")
  end

  test "a passed client must not retain a contradictory blocker", %{root: root} do
    complete_legacy!(root)
    change(root, @legacy, &put_in(&1, ["client", "releaseBlocker"], "still blocked"))
    assert_invalid(root, "passed legacy client retains a release blocker")
  end

  test "required scenario deletion and duplicates cannot shrink the denominator", %{root: root} do
    for transform <- [&tl/1, fn [first | _] = scenarios -> [first | scenarios] end] do
      File.cp!(Path.join(@root, @legacy), Path.join(root, @legacy))

      change(
        root,
        @legacy,
        &update_in(&1, ["client", "requiredNonAuthorizationScenarios"], transform)
      )

      assert_invalid(root, "legacy required scenarios")
    end
  end

  test "a passing modern result requires actual clean checks", %{root: root} do
    for checks <- [
          %{"passed" => 1, "failed" => 1, "warnings" => 0},
          %{"passed" => 1, "failed" => 0, "warnings" => 1},
          %{"passed" => 0, "failed" => 0, "warnings" => 0},
          %{"passed" => -1, "failed" => 0, "warnings" => 0},
          %{"passed" => "8", "failed" => 0, "warnings" => 0},
          %{"passed" => 8, "failed" => 0},
          %{"passed" => 8, "warnings" => 0},
          %{"passed" => 8, "failed" => 0, "warnings" => 0, "skipped" => 1}
        ] do
      File.cp!(Path.join(@root, @modern), Path.join(root, @modern))

      change(
        root,
        @modern,
        &update_in(&1, ["scenarios"], fn [first | rest] ->
          [Map.put(first, "checks", checks) | rest]
        end)
      )

      assert_invalid(root, "checks")
    end
  end

  test "unknown legacy statuses cannot hide beside the known scenarios", %{root: root} do
    change(
      root,
      @legacy,
      &update_in(&1, ["client", "requiredNonAuthorizationScenarios"], fn scenarios ->
        scenarios ++ [%{"name" => "hidden", "status" => "ignored"}]
      end)
    )

    assert_invalid(root, "legacy required scenarios")
  end

  test "a scored modern failure blocks readiness but preserves honest evidence", %{root: root} do
    complete_legacy!(root)

    change(
      root,
      @modern,
      &update_in(&1, ["scenarios"], fn [first | rest] ->
        [
          Map.merge(first, %{
            "status" => "failed",
            "limitation" => "real fixture failure",
            "checks" => %{"passed" => 0, "failed" => 1, "warnings" => 0}
          })
          | rest
        ]
      end)
    )

    assert {_, 0} = run(root)
    assert {output, 1} = run(root, ["--require-ready"])
    assert output =~ "server-caching"
  end

  test "out-of-scope modern results cannot be counted as scored exclusions", %{root: root} do
    change(
      root,
      @modern,
      &update_in(&1, ["scenarios"], fn scenarios ->
        Enum.map(scenarios, fn scenario ->
          if scenario["status"] == "excluded",
            do: Map.put(scenario, "scored", true),
            else: scenario
        end)
      end)
    )

    assert_invalid(root, "excluded modern scenario is scored")
  end

  test "required modern scenarios cannot be deleted from the denominator", %{root: root} do
    change(root, @modern, &update_in(&1, ["scenarios"], fn [_first | rest] -> rest end))
    assert_invalid(root, "modern required scenarios")
  end

  test "required modern checks cannot be silently relabeled out of scope", %{root: root} do
    change(
      root,
      @modern,
      &update_in(&1, ["scenarios"], fn [first | rest] ->
        [
          Map.merge(first, %{
            "status" => "excluded",
            "scored" => false,
            "exclusionReason" => "unapproved scope reduction"
          })
          | rest
        ]
      end)
    )

    assert_invalid(root, "modern required scenarios")
  end

  test "duplicate modern evidence is rejected", %{root: root} do
    change(
      root,
      @modern,
      &update_in(&1, ["scenarios"], fn [first | _] = all -> [first | all] end)
    )

    assert_invalid(root, "duplicate modern scenarios")
  end

  test "harness drift and unrecognized command options fail closed", %{root: root} do
    assert {output, 1} = run(root, ["--require-reddy"])
    assert output =~ "usage:"
    change(root, @legacy, &Map.put(&1, "harness", "latest"))
    assert_invalid(root, "legacy harness pin")
  end

  defp complete_legacy!(root) do
    change(root, @legacy, fn ledger ->
      update_in(ledger, ["client"], &complete_client/1)
    end)
  end

  defp complete_client(client) do
    scenarios = Enum.map(client["requiredNonAuthorizationScenarios"], &passing_scenario/1)

    client
    |> Map.put("status", "passed")
    |> Map.put("requiredNonAuthorizationScenarios", scenarios)
    |> Map.delete("releaseBlocker")
  end

  defp passing_scenario(scenario) do
    scenario
    |> Map.put("status", "passed")
    |> Map.put("checks", %{"passed" => 1, "failed" => 0, "warnings" => 0})
    |> Map.delete("limitation")
  end

  defp change(root, path, fun) do
    path = Path.join(root, path)
    updated = path |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(path, Jason.encode!(updated))
  end

  defp assert_invalid(root, message) do
    assert {output, 1} = run(root)
    assert output =~ message
  end

  defp run(root), do: run(root, [])

  defp run(root, args) do
    System.cmd("elixir", [@script | args],
      cd: root,
      env: [{"ERL_FLAGS", "+S 2:2 +A 2"}],
      stderr_to_stdout: true
    )
  end
end
