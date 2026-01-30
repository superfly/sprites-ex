defmodule Sprites.Filesystem do
  @moduledoc """
  Filesystem operations for sprites.

  Provides file and directory operations similar to Elixir's `File` module,
  but operating on files within a sprite container.

  ## Usage

      fs = Sprites.filesystem(sprite, "/app")
      {:ok, content} = Sprites.Filesystem.read(fs, "config.json")
      :ok = Sprites.Filesystem.write(fs, "output.txt", "data")

  ## Working Directory

  The filesystem struct includes a working directory that serves as the base
  for relative paths. Absolute paths (starting with `/`) are used as-is.
  """

  alias Sprites.Sprite

  @doc """
  Represents a filesystem handle for a sprite.

  ## Fields

    * `:sprite` - The sprite this filesystem operates on
    * `:working_dir` - The working directory for relative paths
  """
  @type t :: %__MODULE__{
          sprite: Sprite.t(),
          working_dir: String.t()
        }

  defstruct [:sprite, :working_dir]

  @doc """
  Creates a new filesystem handle for a sprite.

  ## Examples

      fs = Sprites.Filesystem.new(sprite, "/app")
  """
  @spec new(Sprite.t(), String.t()) :: t()
  def new(%Sprite{} = sprite, working_dir \\ "/") do
    %__MODULE__{
      sprite: sprite,
      working_dir: working_dir
    }
  end

  # ============================================================================
  # Read Operations
  # ============================================================================

  @doc """
  Reads the contents of a file.

  ## Examples

      {:ok, content} = Sprites.Filesystem.read(fs, "config.json")
      {:error, :enoent} = Sprites.Filesystem.read(fs, "missing.txt")
  """
  @spec read(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(%__MODULE__{} = fs, path) do
    url = build_url(fs, "/fs/read", path: resolve_path(fs, path), workingDir: fs.working_dir)

    case Req.get(fs.sprite.client.req, url: url, decode_body: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads the contents of a file, raising on error.

  ## Examples

      content = Sprites.Filesystem.read!(fs, "config.json")
  """
  @spec read!(t(), String.t()) :: binary()
  def read!(fs, path) do
    case read(fs, path) do
      {:ok, content} -> content
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  # ============================================================================
  # Write Operations
  # ============================================================================

  @doc """
  Writes data to a file.

  Creates parent directories if they don't exist.

  ## Options

    * `:mode` - File permissions (default: 0o644)

  ## Examples

      :ok = Sprites.Filesystem.write(fs, "output.txt", "hello world")
      :ok = Sprites.Filesystem.write(fs, "script.sh", "#!/bin/bash", mode: 0o755)
  """
  @spec write(t(), String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(%__MODULE__{} = fs, path, data, opts \\ []) do
    mode = Keyword.get(opts, :mode, 0o644)
    resolved_path = resolve_path(fs, path)

    params = [
      path: resolved_path,
      workingDir: fs.working_dir,
      mode: format_mode(mode),
      mkdirParents: "true"
    ]

    url = build_url(fs, "/fs/write", params)

    case Req.put(fs.sprite.client.req, url: url, body: IO.iodata_to_binary(data)) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Writes data to a file, raising on error.

  ## Examples

      Sprites.Filesystem.write!(fs, "output.txt", "hello world")
  """
  @spec write!(t(), String.t(), iodata(), keyword()) :: :ok
  def write!(fs, path, data, opts \\ []) do
    case write(fs, path, data, opts) do
      :ok -> :ok
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  # ============================================================================
  # Directory Operations
  # ============================================================================

  @doc """
  Lists directory contents.

  ## Examples

      {:ok, entries} = Sprites.Filesystem.ls(fs, "/app")
  """
  @spec ls(t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def ls(%__MODULE__{} = fs, path) do
    url = build_url(fs, "/fs/list", path: resolve_path(fs, path), workingDir: fs.working_dir)

    case Req.get(fs.sprite.client.req, url: url) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        entries = Map.get(body, "entries", [])
        {:ok, entries}

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists directory contents, raising on error.

  ## Examples

      entries = Sprites.Filesystem.ls!(fs, "/app")
  """
  @spec ls!(t(), String.t()) :: [map()]
  def ls!(fs, path) do
    case ls(fs, path) do
      {:ok, entries} -> entries
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  @doc """
  Creates directories recursively (like `mkdir -p`).

  ## Examples

      :ok = Sprites.Filesystem.mkdir_p(fs, "deep/nested/path")
  """
  @spec mkdir_p(t(), String.t()) :: :ok | {:error, term()}
  def mkdir_p(%__MODULE__{} = fs, path) do
    # Write an empty file and rely on mkdirParents to create the directory,
    # then delete the file. Or we can write to a temp path.
    # Actually, let's just use write with a .keep file approach
    resolved_path = resolve_path(fs, path)

    # Create by writing a placeholder and immediately deleting
    # A cleaner approach: ensure parent exists by writing a .keep file
    keep_path = Path.join(resolved_path, ".mkdir_placeholder")

    params = [
      path: keep_path,
      workingDir: fs.working_dir,
      mode: "0644",
      mkdirParents: "true"
    ]

    url = build_url(fs, "/fs/write", params)

    case Req.put(fs.sprite.client.req, url: url, body: "") do
      {:ok, %{status: status}} when status in 200..299 ->
        # Delete the placeholder file
        delete_url =
          build_url(fs, "/fs/delete",
            path: keep_path,
            workingDir: fs.working_dir,
            recursive: "false"
          )

        Req.delete(fs.sprite.client.req, url: delete_url)
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates directories recursively, raising on error.

  ## Examples

      Sprites.Filesystem.mkdir_p!(fs, "deep/nested/path")
  """
  @spec mkdir_p!(t(), String.t()) :: :ok
  def mkdir_p!(fs, path) do
    case mkdir_p(fs, path) do
      :ok -> :ok
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  @doc """
  Removes files or directories recursively (like `rm -rf`).

  ## Examples

      :ok = Sprites.Filesystem.rm_rf(fs, "directory")
  """
  @spec rm_rf(t(), String.t()) :: :ok | {:error, term()}
  def rm_rf(%__MODULE__{} = fs, path) do
    url =
      build_url(fs, "/fs/delete",
        path: resolve_path(fs, path),
        workingDir: fs.working_dir,
        recursive: "true"
      )

    case Req.delete(fs.sprite.client.req, url: url) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        # Already doesn't exist - that's fine for rm_rf
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes files or directories recursively, raising on error.

  ## Examples

      Sprites.Filesystem.rm_rf!(fs, "directory")
  """
  @spec rm_rf!(t(), String.t()) :: :ok
  def rm_rf!(fs, path) do
    case rm_rf(fs, path) do
      :ok -> :ok
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  @doc """
  Removes a single file (not recursive).

  ## Examples

      :ok = Sprites.Filesystem.rm(fs, "file.txt")
  """
  @spec rm(t(), String.t()) :: :ok | {:error, term()}
  def rm(%__MODULE__{} = fs, path) do
    url =
      build_url(fs, "/fs/delete",
        path: resolve_path(fs, path),
        workingDir: fs.working_dir,
        recursive: "false"
      )

    case Req.delete(fs.sprite.client.req, url: url) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes a single file, raising on error.

  ## Examples

      Sprites.Filesystem.rm!(fs, "file.txt")
  """
  @spec rm!(t(), String.t()) :: :ok
  def rm!(fs, path) do
    case rm(fs, path) do
      :ok -> :ok
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  # ============================================================================
  # File Info
  # ============================================================================

  @doc """
  Gets file or directory information.

  Returns a map with file stats including:
    * `"name"` - File/directory name
    * `"size"` - Size in bytes
    * `"mode"` - File permissions
    * `"isDir"` - Whether it's a directory
    * `"modTime"` - Modification time

  ## Examples

      {:ok, stat} = Sprites.Filesystem.stat(fs, "file.txt")
      IO.inspect(stat["size"])
  """
  @spec stat(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stat(%__MODULE__{} = fs, path) do
    # Use ls on the parent directory and find the entry
    resolved_path = resolve_path(fs, path)
    parent_dir = Path.dirname(resolved_path)
    basename = Path.basename(resolved_path)

    url = build_url(fs, "/fs/list", path: parent_dir, workingDir: fs.working_dir)

    case Req.get(fs.sprite.client.req, url: url) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        entries = Map.get(body, "entries", [])

        case Enum.find(entries, fn entry -> entry["name"] == basename end) do
          nil -> {:error, :enoent}
          entry -> {:ok, entry}
        end

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets file or directory information, raising on error.

  ## Examples

      stat = Sprites.Filesystem.stat!(fs, "file.txt")
  """
  @spec stat!(t(), String.t()) :: map()
  def stat!(fs, path) do
    case stat(fs, path) do
      {:ok, stat} -> stat
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  # ============================================================================
  # File Operations
  # ============================================================================

  @doc """
  Renames a file or directory.

  ## Examples

      :ok = Sprites.Filesystem.rename(fs, "old.txt", "new.txt")
  """
  @spec rename(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def rename(%__MODULE__{} = fs, source, dest) do
    body = %{
      source: resolve_path(fs, source),
      dest: resolve_path(fs, dest),
      workingDir: fs.working_dir
    }

    case Req.post(fs.sprite.client.req, url: "/fs/rename", json: body) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Renames a file or directory, raising on error.

  ## Examples

      Sprites.Filesystem.rename!(fs, "old.txt", "new.txt")
  """
  @spec rename!(t(), String.t(), String.t()) :: :ok
  def rename!(fs, source, dest) do
    case rename(fs, source, dest) do
      :ok -> :ok
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: source
    end
  end

  @doc """
  Copies a file or directory.

  ## Options

    * `:recursive` - Copy directories recursively (default: false)

  ## Examples

      :ok = Sprites.Filesystem.cp(fs, "src.txt", "dst.txt")
      :ok = Sprites.Filesystem.cp(fs, "src_dir", "dst_dir", recursive: true)
  """
  @spec cp(t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def cp(%__MODULE__{} = fs, source, dest, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    body = %{
      source: resolve_path(fs, source),
      dest: resolve_path(fs, dest),
      workingDir: fs.working_dir,
      recursive: recursive
    }

    case Req.post(fs.sprite.client.req, url: "/fs/copy", json: body) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Copies a file or directory, raising on error.

  ## Examples

      Sprites.Filesystem.cp!(fs, "src.txt", "dst.txt")
  """
  @spec cp!(t(), String.t(), String.t(), keyword()) :: :ok
  def cp!(fs, source, dest, opts \\ []) do
    case cp(fs, source, dest, opts) do
      :ok -> :ok
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: source
    end
  end

  @doc """
  Changes file permissions.

  ## Options

    * `:recursive` - Apply to directory contents recursively (default: false)

  ## Examples

      :ok = Sprites.Filesystem.chmod(fs, "script.sh", 0o755)
  """
  @spec chmod(t(), String.t(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def chmod(%__MODULE__{} = fs, path, mode, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    body = %{
      path: resolve_path(fs, path),
      workingDir: fs.working_dir,
      mode: mode,
      recursive: recursive
    }

    case Req.post(fs.sprite.client.req, url: "/fs/chmod", json: body) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :enoent}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Changes file permissions, raising on error.

  ## Examples

      Sprites.Filesystem.chmod!(fs, "script.sh", 0o755)
  """
  @spec chmod!(t(), String.t(), non_neg_integer(), keyword()) :: :ok
  def chmod!(fs, path, mode, opts \\ []) do
    case chmod(fs, path, mode, opts) do
      :ok -> :ok
      {:error, reason} -> raise Sprites.Error.FilesystemError, reason: reason, path: path
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp build_url(fs, endpoint, params) do
    Sprites.Sprite.path(fs.sprite, endpoint, params)
  end

  defp resolve_path(_fs, "/" <> _ = absolute_path), do: absolute_path

  defp resolve_path(%__MODULE__{working_dir: working_dir}, relative_path) do
    Path.join(working_dir, relative_path)
  end

  defp format_mode(mode) when is_integer(mode) do
    Integer.to_string(mode, 8)
  end
end
