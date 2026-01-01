defmodule SpritesTestCli do
  @moduledoc """
  Test CLI for Sprites Elixir SDK.
  Compatible with the shared test harness in sdks/test.
  """

  def main(args) do
    {opts, remaining} = parse_args(args)

    token =
      System.get_env("SPRITES_TEST_TOKEN") ||
        (IO.puts(:stderr, "Error: SPRITES_TEST_TOKEN environment variable not set")
         System.halt(1))

    base_url = opts[:base_url] || "https://api.sprites.dev"
    client = Sprites.new(token, base_url: base_url)

    logger =
      if log_target = opts[:log_target] do
        start_logger(log_target)
      end

    result =
      case remaining do
        ["create", name] ->
          handle_create(client, name, logger)

        ["destroy", name] ->
          handle_destroy(client, name, logger)

        [cmd | cmd_args] ->
          handle_exec(client, opts, cmd, cmd_args, logger)

        [] ->
          IO.puts(:stderr, "Error: No command specified")
          {:error, "No command specified"}
      end

    if logger, do: File.close(logger)

    case result do
      :ok -> System.halt(0)
      {:ok, exit_code} -> System.halt(exit_code)
      {:error, _reason} -> System.halt(1)
    end
  end

  defp parse_args(args) do
    parse_args(args, default_opts(), [])
  end

  defp parse_args(["-base-url", url | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :base_url, url), remaining)
  end

  defp parse_args(["-sprite", name | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :sprite, name), remaining)
  end

  defp parse_args(["-dir", dir | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :dir, dir), remaining)
  end

  defp parse_args(["-env", env | rest], opts, remaining) do
    env_list = parse_env(env, opts[:env] || [])
    parse_args(rest, Map.put(opts, :env, env_list), remaining)
  end

  defp parse_args(["-tty" | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :tty, true), remaining)
  end

  defp parse_args(["-tty-rows", rows | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :tty_rows, String.to_integer(rows)), remaining)
  end

  defp parse_args(["-tty-cols", cols | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :tty_cols, String.to_integer(cols)), remaining)
  end

  defp parse_args(["-timeout", duration | rest], opts, remaining) do
    timeout_ms = parse_duration(duration)
    parse_args(rest, Map.put(opts, :timeout, timeout_ms), remaining)
  end

  defp parse_args(["-output", mode | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :output, mode), remaining)
  end

  defp parse_args(["-log-target", path | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :log_target, path), remaining)
  end

  defp parse_args(["-detachable" | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :detachable, true), remaining)
  end

  defp parse_args(["-session-id", id | rest], opts, remaining) do
    parse_args(rest, Map.put(opts, :session_id, id), remaining)
  end

  defp parse_args(["-help" | _rest], _opts, _remaining) do
    print_help()
    System.halt(0)
  end

  defp parse_args(["--help" | _rest], _opts, _remaining) do
    print_help()
    System.halt(0)
  end

  defp parse_args([arg | rest], opts, remaining) do
    parse_args(rest, opts, remaining ++ [arg])
  end

  defp parse_args([], opts, remaining), do: {opts, remaining}

  defp default_opts do
    %{
      base_url: "https://api.sprites.dev",
      output: "default",
      tty: false,
      tty_rows: 24,
      tty_cols: 80
    }
  end

  defp parse_env(env_str, existing) do
    env_str
    |> String.split(",")
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
    |> Kernel.++(existing)
  end

  defp parse_duration(duration) do
    cond do
      String.ends_with?(duration, "ms") ->
        duration |> String.trim_trailing("ms") |> String.to_integer()

      String.ends_with?(duration, "s") ->
        (duration |> String.trim_trailing("s") |> String.to_integer()) * 1000

      String.ends_with?(duration, "m") ->
        (duration |> String.trim_trailing("m") |> String.to_integer()) * 60_000

      String.ends_with?(duration, "h") ->
        (duration |> String.trim_trailing("h") |> String.to_integer()) * 3_600_000

      true ->
        String.to_integer(duration)
    end
  end

  defp format_timeout(nil), do: ""
  defp format_timeout(ms) when is_integer(ms) do
    cond do
      rem(ms, 3_600_000) == 0 -> "#{div(ms, 3_600_000)}h"
      rem(ms, 60_000) == 0 -> "#{div(ms, 60_000)}m"
      rem(ms, 1000) == 0 -> "#{div(ms, 1000)}s"
      true -> "#{ms}ms"
    end
  end

  defp handle_create(client, name, logger) do
    log_event(logger, "sprite_create_start", %{sprite_name: name})

    case Sprites.create(client, name) do
      {:ok, _sprite} ->
        log_event(logger, "sprite_create_completed", %{sprite_name: name})
        :ok

      {:error, reason} ->
        log_event(logger, "sprite_create_failed", %{sprite_name: name, error: inspect(reason)})
        IO.puts(:stderr, "Error creating sprite: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_destroy(client, name, logger) do
    log_event(logger, "sprite_destroy_start", %{sprite_name: name})
    sprite = Sprites.sprite(client, name)

    case Sprites.destroy(sprite) do
      :ok ->
        log_event(logger, "sprite_destroy_completed", %{sprite_name: name})
        :ok

      {:error, reason} ->
        log_event(logger, "sprite_destroy_failed", %{sprite_name: name, error: inspect(reason)})
        IO.puts(:stderr, "Error destroying sprite: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_exec(client, opts, cmd, args, logger) do
    sprite_name =
      opts[:sprite] ||
        (IO.puts(:stderr, "Error: Sprite name required (-sprite flag)")
         System.halt(1))

    sprite = Sprites.sprite(client, sprite_name)

    exec_opts =
      [
        tty: opts[:tty] || false,
        tty_rows: opts[:tty_rows] || 24,
        tty_cols: opts[:tty_cols] || 80,
        env: opts[:env] || [],
        dir: opts[:dir],
        timeout: opts[:timeout],
        detachable: opts[:detachable],
        session_id: opts[:session_id]
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    log_event(logger, "command_start", %{
      sprite: sprite_name,
      command: cmd,
      args: args,
      base_url: opts[:base_url],
      tty: opts[:tty] || false,
      detachable: opts[:detachable] || false,
      session_id: opts[:session_id] || "",
      timeout: format_timeout(opts[:timeout]),
      output: opts[:output] || "default"
    })

    case opts[:output] do
      "stdout" -> exec_stdout_mode(sprite, cmd, args, exec_opts, logger)
      "combined" -> exec_combined_mode(sprite, cmd, args, exec_opts, logger)
      "exit-code" -> exec_exit_code_mode(sprite, cmd, args, exec_opts, logger)
      "default" -> exec_default_mode(sprite, cmd, args, exec_opts, logger)
      _ -> exec_default_mode(sprite, cmd, args, exec_opts, logger)
    end
  end

  defp exec_stdout_mode(sprite, cmd, args, opts, logger) do
    try do
      {output, exit_code} = Sprites.cmd(sprite, cmd, args, opts)
      IO.write(output)
      log_event(logger, "command_completed", %{exit_code: exit_code, output_length: byte_size(output)})
      {:ok, exit_code}
    rescue
      e in Sprites.Error.TimeoutError ->
        log_event(logger, "command_timeout", %{timeout: e.timeout})
        IO.puts(:stderr, "Error: command timed out after #{e.timeout}ms")
        {:ok, 124}

      e ->
        log_event(logger, "command_failed", %{error: Exception.message(e)})
        IO.puts(:stderr, "Error: #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp exec_combined_mode(sprite, cmd, args, opts, logger) do
    opts = Keyword.put(opts, :stderr_to_stdout, true)

    try do
      {output, exit_code} = Sprites.cmd(sprite, cmd, args, opts)
      IO.write(output)
      log_event(logger, "command_completed", %{exit_code: exit_code, output_length: byte_size(output)})
      {:ok, exit_code}
    rescue
      e in Sprites.Error.TimeoutError ->
        log_event(logger, "command_timeout", %{timeout: e.timeout})
        IO.puts(:stderr, "Error: command timed out after #{e.timeout}ms")
        {:ok, 124}

      e ->
        log_event(logger, "command_failed", %{error: Exception.message(e)})
        IO.puts(:stderr, "Error: #{Exception.message(e)}")
        {:error, e}
    end
  end

  defp exec_exit_code_mode(sprite, cmd, args, opts, logger) do
    try do
      {_output, exit_code} = Sprites.cmd(sprite, cmd, args, opts)
      log_event(logger, "command_completed", %{exit_code: exit_code})
      {:ok, exit_code}
    rescue
      e in Sprites.Error.TimeoutError ->
        log_event(logger, "command_timeout", %{timeout: e.timeout})
        {:ok, 124}

      e ->
        log_event(logger, "command_failed", %{error: Exception.message(e)})
        {:ok, 1}
    end
  end

  defp exec_default_mode(sprite, cmd, args, opts, logger) do
    case Sprites.spawn(sprite, cmd, args, opts) do
      {:ok, command} ->
        # Start stdin reader task if not TTY
        unless opts[:tty] do
          spawn(fn -> forward_stdin(command) end)
        end

        stream_output(command, logger)

      {:error, reason} ->
        log_event(logger, "command_failed", %{error: inspect(reason)})
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp forward_stdin(command) do
    case IO.binread(:stdio, :line) do
      :eof ->
        Sprites.close_stdin(command)

      {:error, _} ->
        Sprites.close_stdin(command)

      data ->
        Sprites.write(command, data)
        forward_stdin(command)
    end
  end

  defp stream_output(command, logger) do
    ref = command.ref

    receive do
      {:stdout, %{ref: ^ref}, data} ->
        IO.write(data)
        stream_output(command, logger)

      {:stderr, %{ref: ^ref}, data} ->
        IO.write(:stderr, data)
        stream_output(command, logger)

      {:exit, %{ref: ^ref}, code} ->
        log_event(logger, "command_completed", %{exit_code: code})
        {:ok, code}

      {:error, %{ref: ^ref}, reason} ->
        log_event(logger, "command_failed", %{error: inspect(reason)})
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Logger helpers

  defp start_logger(path) do
    case File.open(path, [:append, :utf8]) do
      {:ok, file} -> file
      {:error, _} -> nil
    end
  end

  defp log_event(nil, _type, _data), do: :ok

  defp log_event(file, type, data) do
    event = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: type,
      data: data
    }

    IO.write(file, Jason.encode!(event) <> "\n")
    :ok
  end

  defp print_help do
    IO.puts("""
    Sprites Test CLI - Elixir SDK

    Usage:
      test-cli [options] <command> [args...]
      test-cli create <sprite-name>
      test-cli destroy <sprite-name>

    Options:
      -base-url <url>     API base URL (default: https://api.sprites.dev)
      -sprite <name>      Sprite name (required for exec commands)
      -output <mode>      Output mode: stdout, combined, exit-code, default
      -tty                Enable TTY mode
      -tty-rows <int>     TTY rows (default: 24)
      -tty-cols <int>     TTY columns (default: 80)
      -timeout <duration> Command timeout (e.g., 10s, 5m)
      -dir <path>         Working directory
      -env key=val,...    Environment variables
      -log-target <path>  JSON event log file
      -detachable         Enable detachable session
      -session-id <id>    Attach to existing session
      -help               Show this help

    Environment Variables:
      SPRITES_TEST_TOKEN  Authentication token (required)

    Examples:
      test-cli create my-sprite
      test-cli -sprite my-sprite -output stdout echo hello
      test-cli -sprite my-sprite -tty bash
      test-cli destroy my-sprite
    """)
  end
end
