package bo.edu.uagrm.saludu.shared.api;

public record CsrfTokenResponse(String token, String headerName, String parameterName) {
}
