defmodule SyncServer.Auth.JWTVerifier do
  @moduledoc """
  Verifies JWT tokens for WebSocket authentication.

  Supports:
  - HS256 (symmetric) tokens verified with a shared secret
  - RS256 (asymmetric) tokens verified with public keys

  ## Configuration

  Set JWT_SECRET environment variable for HS256 verification:

      JWT_SECRET=your_secret_here

  For RS256, set the public key:

      JWT_PUBLIC_KEY=-----BEGIN PUBLIC KEY-----...
  """

  use Joken.Config

  @impl true
  def token_config do
    default_claims(skip: [:aud, :iss])
  end

  @doc """
  Verifies a JWT token.
  Returns {:ok, claims} on success, {:error, reason} on failure.

  Tries HS256 first (if JWT_SECRET is configured), then RS256.
  """
  def verify_token(token, _client_id) do
    jwt_secret = System.get_env("JWT_SECRET")

    cond do
      jwt_secret != nil ->
        verify_hs256(token, jwt_secret)

      System.get_env("JWT_PUBLIC_KEY") != nil ->
        verify_rs256(token, System.get_env("JWT_PUBLIC_KEY"))

      true ->
        {:error, :no_jwt_config}
    end
  end

  @doc """
  Verify an HS256 JWT token with the given secret.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_hs256(token, secret) do
    case String.split(token, ".") do
      [header_b64, payload_b64, signature_b64] ->
        expected_sig = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")
        expected_sig_b64 = Base.url_encode64(expected_sig, padding: false)

        if signature_b64 == expected_sig_b64 do
          case Base.url_decode64(payload_b64, padding: false) do
            {:ok, payload_json} ->
              claims = Jason.decode!(payload_json)
              if claims["exp"] > System.system_time(:second) do
                {:ok, claims}
              else
                {:error, :token_expired}
              end

            :error ->
              {:error, :invalid_token_format}
          end
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  @doc """
  Verify an RS256 JWT token with the given public key PEM.
  """
  def verify_rs256(token, public_key_pem) do
    signer = Joken.Signer.create("RS256", %{"pem" => public_key_pem})
    case verify_and_validate(token, signer) do
      {:ok, claims} -> {:ok, claims}
      error -> error
    end
  end
end
