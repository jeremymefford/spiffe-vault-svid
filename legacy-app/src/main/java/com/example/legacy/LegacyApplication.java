package com.example.legacy;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.openssl.PEMKeyPair;
import org.bouncycastle.openssl.PEMParser;
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.ByteArrayInputStream;
import java.io.StringReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Security;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;

@SpringBootApplication
public class LegacyApplication implements CommandLineRunner {

    private final ObjectMapper mapper = new ObjectMapper();

    public static void main(String[] args) {
        // Must be set before HttpClient is initialized; modern-app presents URI SAN-only certs in this lab.
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
        Security.addProvider(new BouncyCastleProvider());
        SpringApplication.run(LegacyApplication.class, args);
    }

    @Override
    public void run(String... args) throws Exception {
        String vaultAddr = requiredEnv("LAB_VAULT_ADDR");
        String roleId = requiredEnv("LAB_VAULT_ROLE_ID");
        String secretId = requiredEnv("LAB_VAULT_SECRET_ID");
        String keyStorePassword = requiredEnv("LAB_KEYSTORE_PASSWORD");
        String spiffeId = envOrDefault("LAB_LEGACY_SPIFFE_ID", "spiffe://legacy.lab/ns/legacy/sa/springboot");
        String modernUrl = envOrDefault("LAB_MODERN_URL", "https://localhost:30443/hello");
        String modernRootCaPem = normalizePem(envOrDefault("LAB_MODERN_ROOT_CA_PEM", ""));

        String vaultToken = loginWithAppRole(vaultAddr, roleId, secretId);
        IssuedSvid issuedSvid = mintSvid(vaultAddr, vaultToken, spiffeId);

        SSLContext sslContext = buildSslContext(
                issuedSvid.certificate(),
                issuedSvid.privateKey(),
                issuedSvid.issuingCa(),
                keyStorePassword,
                modernRootCaPem
        );

        HttpClient client = HttpClient.newBuilder()
                .sslContext(sslContext)
                .connectTimeout(Duration.ofSeconds(10))
                .build();

        HttpRequest request = HttpRequest.newBuilder(URI.create(modernUrl))
                .timeout(Duration.ofSeconds(10))
                .GET()
                .build();

        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());

        System.out.println("Legacy app SPIFFE ID minted by Vault: " + spiffeId);
        System.out.println("Modern app status: " + response.statusCode());
        System.out.println("Modern app response: " + response.body().trim());
    }

    private String loginWithAppRole(String vaultAddr, String roleId, String secretId) throws Exception {
        String payload = mapper.createObjectNode()
                .put("role_id", roleId)
                .put("secret_id", secretId)
                .toString();

        HttpResponse<String> response = unauthenticatedClient()
                .send(post(vaultAddr + "/v1/auth/approle/login", payload), HttpResponse.BodyHandlers.ofString());

        ensureSuccess(response, "Vault AppRole login");
        JsonNode root = mapper.readTree(response.body());
        JsonNode token = root.path("auth").path("client_token");
        if (token.isMissingNode() || token.asText().isEmpty()) {
            throw new IllegalStateException("Vault did not return a client_token");
        }
        return token.asText();
    }

    private IssuedSvid mintSvid(String vaultAddr, String vaultToken, String spiffeId) throws Exception {
        String payload = mapper.createObjectNode()
                .put("common_name", "legacy-app.lab")
                .put("uri_sans", spiffeId)
                .put("ttl", "30m")
                .toString();

        HttpRequest request = HttpRequest.newBuilder(URI.create(vaultAddr + "/v1/pki/issue/legacy-svid"))
                .timeout(Duration.ofSeconds(10))
                .header("Content-Type", "application/json")
                .header("X-Vault-Token", vaultToken)
                .POST(HttpRequest.BodyPublishers.ofString(payload))
                .build();

        HttpResponse<String> response = unauthenticatedClient().send(request, HttpResponse.BodyHandlers.ofString());
        ensureSuccess(response, "Vault x509-SVID issue");

        JsonNode data = mapper.readTree(response.body()).path("data");
        return new IssuedSvid(
                requiredNodeText(data, "certificate"),
                requiredNodeText(data, "private_key"),
                requiredNodeText(data, "issuing_ca")
        );
    }

    private SSLContext buildSslContext(
            String certificatePem,
            String privateKeyPem,
            String issuingCaPem,
            String keyStorePassword,
            String modernRootCaPem
    ) throws Exception {
        List<X509Certificate> chain = new ArrayList<>();
        chain.addAll(parseCertificates(certificatePem));
        chain.addAll(parseCertificates(issuingCaPem));

        PrivateKey privateKey = parsePrivateKey(privateKeyPem);
        char[] keyPass = keyStorePassword.toCharArray();

        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        keyStore.load(null, null);
        keyStore.setKeyEntry("legacy", privateKey, keyPass, chain.toArray(new Certificate[0]));

        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(keyStore, keyPass);

        KeyStore trustStore = KeyStore.getInstance("PKCS12");
        trustStore.load(null, null);
        trustStore.setCertificateEntry("ca", chain.get(chain.size() - 1));
        if (!modernRootCaPem.isBlank()) {
            int index = 0;
            for (X509Certificate cert : parseCertificates(modernRootCaPem)) {
                trustStore.setCertificateEntry("modern-ca-" + index, cert);
                index++;
            }
        }

        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trustStore);

        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);
        return sslContext;
    }

    private List<X509Certificate> parseCertificates(String pem) throws Exception {
        CertificateFactory factory = CertificateFactory.getInstance("X.509");
        Collection<? extends Certificate> certificates = factory.generateCertificates(
                new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8))
        );

        List<X509Certificate> parsed = new ArrayList<>();
        for (Certificate certificate : certificates) {
            parsed.add((X509Certificate) certificate);
        }

        if (parsed.isEmpty()) {
            throw new IllegalStateException("No certificates found in PEM block");
        }
        return parsed;
    }

    private PrivateKey parsePrivateKey(String privateKeyPem) throws Exception {
        try (PEMParser parser = new PEMParser(new StringReader(privateKeyPem))) {
            Object object = parser.readObject();
            JcaPEMKeyConverter converter = new JcaPEMKeyConverter().setProvider("BC");

            if (object instanceof PEMKeyPair pemKeyPair) {
                KeyPair pair = converter.getKeyPair(pemKeyPair);
                return pair.getPrivate();
            }
            if (object instanceof PrivateKeyInfo privateKeyInfo) {
                return converter.getPrivateKey(privateKeyInfo);
            }
            throw new IllegalStateException("Unsupported private key format from Vault: " + object);
        }
    }

    private HttpClient unauthenticatedClient() {
        return HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(10))
                .build();
    }

    private HttpRequest post(String url, String payload) {
        return HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(10))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(payload))
                .build();
    }

    private void ensureSuccess(HttpResponse<String> response, String action) {
        if (response.statusCode() / 100 == 2) {
            return;
        }
        throw new IllegalStateException(action + " failed with status " + response.statusCode() + ": " + response.body());
    }

    private String requiredNodeText(JsonNode node, String fieldName) {
        JsonNode field = node.path(fieldName);
        if (field.isMissingNode() || field.asText().isEmpty()) {
            throw new IllegalStateException("Missing field in Vault response: " + fieldName);
        }
        return field.asText();
    }

    private String requiredEnv(String key) {
        String value = System.getenv(key);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("Environment variable is required: " + key);
        }
        return value;
    }

    private String envOrDefault(String key, String fallback) {
        String value = System.getenv(key);
        if (value == null || value.isBlank()) {
            return fallback;
        }
        return value;
    }

    private String normalizePem(String pem) {
        return pem.replace("\\n", "\n");
    }

    private record IssuedSvid(String certificate, String privateKey, String issuingCa) {
    }
}
