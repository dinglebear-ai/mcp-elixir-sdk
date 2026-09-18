defmodule MCP.PackageSmoke do
  @moduledoc false

  def run!, do: run!(:all)

  def run!(sources) do
    root = File.cwd!()
    temp_root = package_temp_root()
    package_root = Path.join(temp_root, "package")

    File.mkdir_p!(temp_root)

    try do
      run!("mix", ["hex.build", "--unpack", "--output", package_root], root)
      assert_packaged_files!(package_root)
      run!("mix", ["deps.get", "--only", "prod"], package_root, [{"MIX_ENV", "prod"}])

      run!(
        "mix",
        ["compile", "--warnings-as-errors"],
        package_root,
        [{"MIX_ENV", "prod"}]
      )

      run!(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          quickstart_assertion()
        ],
        package_root,
        [{"MIX_ENV", "prod"}]
      )

      consumer_smoke!(temp_root, :package_consumer, {:plexus, path: package_root})

      if sources == :all do
        consumer_smoke!(temp_root, :readme_consumer, readme_dependency!(root))
      end

      IO.puts("package and consumer smoke passed from #{package_root}")
    after
      File.rm_rf!(temp_root)
    end
  end

  def run_readme! do
    root = File.cwd!()
    temp_root = package_temp_root()
    File.mkdir_p!(temp_root)

    try do
      consumer_smoke!(temp_root, :readme_consumer, readme_dependency!(root))
    after
      File.rm_rf!(temp_root)
    end
  end

  defp readme_dependency!(root) do
    installation =
      root
      |> Path.join("README.md")
      |> File.read!()
      |> String.split("## Installation\n", parts: 2)
      |> Enum.at(1, "")
      |> String.split("\n## ", parts: 2)
      |> hd()

    pattern =
      ~r/\{:plexus,\s*git:\s*"(https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git)",\s*ref:\s*"([a-f0-9]{40})"\s*\}/

    case Regex.run(pattern, installation) do
      [_, url, ref] -> {:plexus, git: url, ref: ref}
      _ -> raise "README must advertise a :plexus Git dependency pinned to an immutable commit"
    end
  end

  defp consumer_smoke!(temp_root, app, dependency) do
    consumer_root = Path.join(temp_root, Atom.to_string(app))
    File.mkdir_p!(consumer_root)

    File.write!(Path.join(consumer_root, "mix.exs"), """
    defmodule ConsumerSmoke.MixProject do
      use Mix.Project
      def project do
        [app: #{inspect(app)}, version: "0.0.0", deps: [#{inspect(dependency)}]]
      end
      def application, do: [extra_applications: [:logger]]
    end
    """)

    env = [
      {"MIX_ENV", "prod"},
      {"MIX_DEPS_PATH", nil},
      {"MIX_BUILD_PATH", nil},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]

    run!("mix", ["deps.get"], consumer_root, env)
    run!("mix", ["compile", "--warnings-as-errors"], consumer_root, env)
    run!("mix", ["run", "--no-start", "-e", consumer_assertion()], consumer_root, env)
    IO.puts("#{app} passed: #{inspect(dependency)}")
  end

  defp consumer_assertion do
    ~S'''
    {:ok, _apps} = Application.ensure_all_started(:plexus)
    {Plexus.Application, []} = Application.spec(:plexus, :mod)
    nil = Application.spec(:mcp_elixir_sdk)
    true = is_pid(Process.whereis(Plexus.Supervisor))
    true = Code.ensure_loaded?(MCP.Client)
    false = Code.ensure_loaded?(Bandit)
    version = to_string(Application.spec(:plexus, :vsn))
    ^version = MCP.Version.current()
    {:ok, response} = MCP.Protocol.decode(~s({"jsonrpc":"2.0","id":7,"result":{"ok":true}}))
    {:ok, ^response} = response |> MCP.Protocol.encode!() |> MCP.Protocol.decode()
    dependency_root = Map.fetch!(Mix.Project.deps_paths(), :plexus)
    Code.require_file(Path.join(dependency_root, "examples/quickstart_server.exs"))
    alias MCP.Examples.QuickstartServer.Handler
    alias MCP.Server.ToolContext
    {:ok, %{}} = Handler.init([])
    {:ok, [%{"type" => "text", "text" => "42"}]} =
      Handler.handle_call_tool("add", %{"a" => 20, "b" => 22}, struct!(ToolContext), %{})
    IO.puts("consumer startup, application identity, version and MCP roundtrip passed")
    '''
  end

  defp assert_packaged_files!(package_root) do
    for relative <- [
          "README.md",
          "LICENSE",
          "CHANGELOG.md",
          "usage-rules.md",
          "docs/dev-tooling.md",
          "conformance/scenarios.json",
          "examples/quickstart_server.exs"
        ] do
      path = Path.join(package_root, relative)
      if not File.regular?(path), do: raise("package is missing #{relative}")
    end

    generated_dependency_trees = Path.wildcard(Path.join(package_root, "**/node_modules"))

    if generated_dependency_trees != [] do
      raise("package contains generated dependency trees: #{inspect(generated_dependency_trees)}")
    end

    for relative <- [
          "conformance/apps_browser_adapter.exs",
          "conformance/apps_browser_handler.ex",
          "conformance/apps_browser_interop.mjs",
          "conformance/browser/package-lock.json"
        ] do
      if File.exists?(Path.join(package_root, relative)) do
        raise("package contains browser-only interoperability fixture #{relative}")
      end
    end
  end

  defp run!(command, args, directory, extra_env \\ []) do
    IO.puts("==> (package) #{Enum.join([command | args], " ")}")

    env = merge_env(extra_env)

    case System.cmd(command, args,
           cd: directory,
           env: env,
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> raise("#{command} #{Enum.join(args, " ")} exited with status #{status}")
    end
  end

  defp merge_env(extra_env) do
    base =
      System.get_env()
      |> Map.take(["PATH", "HOME", "MIX_HOME", "HEX_HOME"])
      |> Map.to_list()

    base
    |> Map.new()
    |> Map.put("ERL_FLAGS", "+S 2:2 +A 2")
    |> Map.merge(Map.new(extra_env))
    |> Map.to_list()
  end

  defp quickstart_assertion do
    ~S|Code.require_file("examples/quickstart_server.exs"); alias MCP.Examples.QuickstartServer.Handler; alias MCP.Server.ToolContext; {:ok, %{}} = Handler.init([]); {:ok, [%{"type" => "text", "text" => "42"}]} = Handler.handle_call_tool("add", %{"a" => 20, "b" => 22}, %ToolContext{}, %{})|
  end

  defp package_temp_root do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "plexus-package-smoke-#{suffix}")
  end
end

case System.argv() do
  [] -> MCP.PackageSmoke.run!()
  ["--readme-only"] -> MCP.PackageSmoke.run_readme!()
  ["--package-only"] -> MCP.PackageSmoke.run!(:package)
  args -> raise ArgumentError, "unsupported package smoke arguments: #{inspect(args)}"
end
