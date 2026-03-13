defmodule PiEx.Image do
  @moduledoc """
  Image handling for pi agent prompts.

  Images can be included with prompts for vision-capable models.

  ## Examples

      # From file
      image = PiEx.Image.from_file!("screenshot.png")

      # From base64
      image = PiEx.Image.from_base64("iVBORw0KGgo...", :png)

      # From URL (model will fetch)
      image = PiEx.Image.from_url("https://example.com/image.png")

      # Include with prompt
      PiEx.prompt(session, "What's in this image?", images: [image])
  """

  @type t :: %__MODULE__{
          type: :base64 | :url,
          media_type: String.t(),
          data: String.t()
        }

  defstruct [:type, :media_type, :data]

  @type media_type :: :png | :jpeg | :gif | :webp | String.t()

  @doc """
  Creates an image from a file path.

  Reads the file and encodes it as base64. The media type is inferred
  from the file extension.

  ## Examples

      image = PiEx.Image.from_file!("screenshot.png")
      image = PiEx.Image.from_file!("photo.jpg")
  """
  @spec from_file!(Path.t()) :: t()
  def from_file!(path) do
    data = File.read!(path)
    media_type = infer_media_type(path)

    %__MODULE__{
      type: :base64,
      media_type: media_type,
      data: Base.encode64(data)
    }
  end

  @doc """
  Creates an image from a file path, returning an error tuple on failure.
  """
  @spec from_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def from_file(path) do
    {:ok, from_file!(path)}
  rescue
    e -> {:error, e}
  end

  @doc """
  Creates an image from base64-encoded data.

  ## Examples

      image = PiEx.Image.from_base64(base64_data, :png)
      image = PiEx.Image.from_base64(base64_data, "image/jpeg")
  """
  @spec from_base64(String.t(), media_type()) :: t()
  def from_base64(data, media_type) do
    %__MODULE__{
      type: :base64,
      media_type: normalize_media_type(media_type),
      data: data
    }
  end

  @doc """
  Creates an image from raw binary data.

  ## Examples

      image = PiEx.Image.from_binary(png_bytes, :png)
  """
  @spec from_binary(binary(), media_type()) :: t()
  def from_binary(data, media_type) do
    %__MODULE__{
      type: :base64,
      media_type: normalize_media_type(media_type),
      data: Base.encode64(data)
    }
  end

  @doc """
  Creates an image from a URL.

  The model will fetch the image from the URL.

  ## Examples

      image = PiEx.Image.from_url("https://example.com/image.png")
  """
  @spec from_url(String.t()) :: t()
  def from_url(url) do
    %__MODULE__{
      type: :url,
      media_type: infer_media_type(url),
      data: url
    }
  end

  @doc """
  Converts an image to the format expected by the pi SDK.
  """
  @spec to_js(t()) :: map()
  def to_js(%__MODULE__{type: :base64} = image) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => image.media_type,
        "data" => image.data
      }
    }
  end

  def to_js(%__MODULE__{type: :url} = image) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "url",
        "url" => image.data
      }
    }
  end

  # Private helpers

  defp infer_media_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/png"
    end
  end

  defp normalize_media_type(:png), do: "image/png"
  defp normalize_media_type(:jpeg), do: "image/jpeg"
  defp normalize_media_type(:jpg), do: "image/jpeg"
  defp normalize_media_type(:gif), do: "image/gif"
  defp normalize_media_type(:webp), do: "image/webp"
  defp normalize_media_type(type) when is_binary(type), do: type
end
