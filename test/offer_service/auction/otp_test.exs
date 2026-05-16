defmodule OfferService.Auction.OTPTest do
  use ExUnit.Case, async: true

  alias OfferService.Auction.OTP

  test "generate returns a 4-digit code, sha256 hash, and last-2 hint" do
    %{code: code, code_hash: hash, code_last2: last2, expires_at: expires_at} = OTP.generate(15)

    assert code =~ ~r/^\d{4}$/
    assert hash == :crypto.hash(:sha256, code)
    assert String.length(last2) == 2
    assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  test "verify accepts the matching plaintext" do
    %{code: code, code_hash: hash} = OTP.generate()
    assert OTP.verify(code, hash)
  end

  test "verify rejects a different plaintext" do
    %{code: code, code_hash: hash} = OTP.generate()
    other = if code == "9999", do: "0000", else: "9999"
    refute OTP.verify(other, hash)
  end

  test "verify rejects a different hash entirely" do
    refute OTP.verify("1234", <<0::256>>)
  end

  test "1000 generations all produce 4-digit codes" do
    for _ <- 1..1_000 do
      %{code: code} = OTP.generate()
      assert byte_size(code) == 4
      assert code =~ ~r/^\d{4}$/
    end
  end
end
