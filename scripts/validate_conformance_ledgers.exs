defmodule MCP.ValidateConformanceLedgers do
  @moduledoc false

  @harness "@modelcontextprotocol/conformance@0.2.0-alpha.11"
  @legacy_scenarios ~w(initialize tools_call elicitation-sep1034-client-defaults sse-retry)
  @statuses ~w(passed failed partial excluded)

  def run!(args) do
    mode = mode!(args)
    modern = decode!("conformance/scenarios.json")
    legacy = decode!("conformance/compatibility-2025-11-25.json")

    require_equal!(modern["harness"], @harness, "modern harness pin")
    require_equal!(modern["protocolVersion"], "2026-07-28", "modern protocol version")
    validate_modern_scenarios!(modern["scenarios"])
    validate_exclusions!(modern["excludedProfiles"])

    require_equal!(legacy["harness"], @harness, "legacy harness pin")
    require_equal!(legacy["protocolVersion"], "2025-11-25", "legacy protocol version")

    require_equal!(
      legacy["server"]["profile"],
      "requirements:2025-11-25",
      "legacy server profile"
    )

    require_equal!(legacy["server"]["status"], "passed", "legacy server status")
    validate_checks!(legacy["server"], "legacy server")
    validate_legacy_client!(legacy["client"])

    blockers = blockers(modern["scenarios"], legacy["client"])

    report = %{
      "schemaVersion" => 1,
      "harness" => @harness,
      "ledgerReadiness" => if(blockers == [], do: "ready", else: "blocked"),
      "freshCandidateEvidenceRequired" => true,
      "blockers" => blockers
    }

    emit(report, mode)

    if mode == :require_ready and blockers != [] do
      raise "conformance release prerequisite blocked: #{Enum.join(blockers, "; ")}"
    end
  end

  defp mode!([]), do: :human
  defp mode!(["--json"]), do: :json
  defp mode!(["--require-ready"]), do: :require_ready

  defp mode!(_),
    do:
      raise(
        ArgumentError,
        "usage: elixir scripts/validate_conformance_ledgers.exs [--json | --require-ready]"
      )

  defp decode!(path) do
    # OTP 27's decoder also works under the supported Elixir 1.17 toolchain.
    case path |> File.read!() |> :json.decode() do
      value when is_map(value) -> value
      _ -> raise "#{path} must contain an object"
    end
  end

  defp validate_modern_scenarios!(scenarios) when is_list(scenarios) and scenarios != [] do
    identities = Enum.map(scenarios, &{&1["side"], &1["name"]})

    if length(Enum.uniq(identities)) != length(identities),
      do: raise("duplicate modern scenarios")

    for side <- ["client", "server"] do
      unless Enum.any?(scenarios, &(&1["side"] == side and &1["scored"] == true)),
        do: raise("modern ledger has no scored #{side} scenarios")
    end

    Enum.each(scenarios, &validate_modern_scenario!/1)
  end

  defp validate_modern_scenarios!(_), do: raise("modern ledger has no scenarios")

  defp validate_modern_scenario!(scenario) do
    name = scenario["name"]
    require_present!(name, "modern scenario name")
    unless scenario["side"] in ["client", "server"], do: raise("invalid modern scenario side")
    validate_status!(scenario, "modern scenario #{name}")

    if scenario["status"] == "excluded" do
      unless scenario["scored"] == false, do: raise("excluded modern scenario is scored: #{name}")
      require_present!(scenario["exclusionReason"], "modern exclusion reason #{name}")
    else
      require_equal!(scenario["scored"], true, "modern scored scenario #{name}")
      require_limitation!(scenario, "modern scenario #{name}")
    end

    validate_checks!(scenario, "modern scenario #{name}")
  end

  defp validate_exclusions!(profiles) when is_list(profiles) do
    Enum.each(profiles, fn profile ->
      require_present!(profile["exclusionReason"], "modern profile exclusion reason")
      require_equal!(profile["status"], "excluded", "modern excluded profile status")
      require_equal!(profile["scored"], false, "modern excluded profile scoring")
    end)
  end

  defp validate_exclusions!(_), do: raise("modern excludedProfiles must be a list")

  defp validate_legacy_client!(client) when is_map(client) do
    scenarios = client["requiredNonAuthorizationScenarios"]
    validate_legacy_scenarios!(scenarios)
    complete? = Enum.all?(scenarios, &(&1["status"] == "passed"))

    require_equal!(
      client["status"],
      if(complete?, do: "passed", else: "incomplete"),
      "legacy client status"
    )

    if complete? do
      unless is_nil(client["releaseBlocker"]),
        do: raise("passed legacy client retains a release blocker")
    else
      require_present!(client["releaseBlocker"], "legacy release blocker")
    end
  end

  defp validate_legacy_client!(_), do: raise("legacy client must be an object")

  defp validate_legacy_scenarios!(scenarios) when is_list(scenarios) do
    require_equal!(
      Enum.sort(Enum.map(scenarios, & &1["name"])),
      Enum.sort(@legacy_scenarios),
      "legacy required scenarios"
    )

    Enum.each(scenarios, fn scenario ->
      label = "legacy scenario #{scenario["name"]}"
      validate_status!(scenario, label)
      require_limitation!(scenario, label)
      validate_checks!(scenario, label)
    end)
  end

  defp validate_legacy_scenarios!(_), do: raise("legacy required scenarios must be a list")

  defp validate_status!(scenario, label) do
    unless scenario["status"] in @statuses, do: raise("#{label} has invalid status")
  end

  defp require_limitation!(%{"status" => "passed"}, _label), do: :ok

  defp require_limitation!(scenario, label),
    do: require_present!(scenario["limitation"], "#{label} limitation")

  defp validate_checks!(%{"checks" => checks, "status" => status}, label) when is_map(checks) do
    for key <- ["passed", "failed", "warnings", "skipped"] do
      optional? = key == "skipped" or (key == "warnings" and status == "excluded")
      value = Map.get(checks, key, if(optional?, do: 0))
      unless is_integer(value) and value >= 0, do: raise("#{label} has invalid #{key} checks")
    end

    if status == "passed" and
         (checks["passed"] == 0 or checks["failed"] != 0 or
            Map.get(checks, "warnings", 0) != 0 or Map.get(checks, "skipped", 0) != 0) do
      raise "#{label} claims passed without clean, nonzero checks"
    end
  end

  defp validate_checks!(_scenario, label), do: raise("#{label} has no checks")

  defp blockers(modern, client) do
    modern_blockers =
      for s <- modern,
          s["scored"] == true,
          s["status"] != "passed",
          do: "2026-07-28/#{s["side"]}/#{s["name"]}: #{s["status"]}"

    legacy_blockers =
      for s <- client["requiredNonAuthorizationScenarios"],
          s["status"] != "passed",
          do: "2025-11-25/client/#{s["name"]}: #{s["status"]}"

    modern_blockers ++ legacy_blockers
  end

  defp emit(report, :json), do: report |> :json.encode() |> IO.iodata_to_binary() |> IO.puts()

  defp emit(report, _mode) do
    IO.puts("conformance ledger validation passed")

    IO.puts(
      "ledger readiness: #{report["ledgerReadiness"]}; fresh candidate evidence is still required"
    )

    Enum.each(report["blockers"], &IO.puts("  blocker: #{&1}"))
  end

  defp require_equal!(actual, expected, _label) when actual == expected, do: :ok

  defp require_equal!(actual, expected, label),
    do: raise("#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}")

  defp require_present!(value, label) do
    unless is_binary(value) and String.trim(value) != "", do: raise("#{label} is missing")
  end
end

MCP.ValidateConformanceLedgers.run!(System.argv())
