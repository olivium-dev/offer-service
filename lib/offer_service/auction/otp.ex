defmodule OfferService.Auction.OTP do
  @moduledoc """
  4-digit acceptance OTP generation. The plaintext code is returned exactly
  once to the calling layer (so the API can return it to the Client) and is
  never persisted in cleartext — only a SHA-256 hash is stored.
  """

  @default_ttl_minutes 60

  @type code :: <<_::32>>
  @type generated :: %{
          code: code,
          code_hash: binary,
          code_last2: binary,
          expires_at: DateTime.t()
        }

  @spec generate(pos_integer()) :: generated()
  def generate(ttl_minutes \\ @default_ttl_minutes) when ttl_minutes > 0 do
    length = Application.get_env(:offer_service, :otp_length, 4)
    max = trunc(:math.pow(10, length))
    code = (:rand.uniform(max) - 1) |> Integer.to_string() |> String.pad_leading(length, "0")
    expires_at = DateTime.utc_now() |> DateTime.add(ttl_minutes * 60, :second)

    %{
      code: code,
      code_hash: :crypto.hash(:sha256, code),
      code_last2: String.slice(code, -2, 2),
      expires_at: expires_at
    }
  end

  @doc "Constant-time check that a presented OTP matches the stored hash."
  @spec verify(binary(), binary()) :: boolean()
  def verify(presented, hash) when is_binary(presented) and is_binary(hash) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, presented), hash)
  end
end
