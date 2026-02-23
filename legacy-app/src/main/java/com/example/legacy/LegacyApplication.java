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
import java.security.MessageDigest;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
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
        String kvPath = envOrDefault("LAB_VAULT_KV_PATH", "kv/data/legacy-app");
        String svidTtl = envOrDefault("LAB_SVID_TTL", "5m");

        String vaultToken = loginWithAppRole(vaultAddr, roleId, secretId);
        IssuedSvid issuedSvid = mintSvid(vaultAddr, vaultToken, spiffeId, svidTtl);

        logTrustBundle("Legacy app trust bundle (modern root)", modernRootCaPem);
        logSvidMetadata("Vault-issued legacy SVID", issuedSvid.certificate());
        String kvMessage = fetchKvMessage(vaultAddr, vaultToken, kvPath);
        if (kvMessage != null) {
            System.out.println("Legacy app KV v2 message: " + kvMessage);
        }

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

    private IssuedSvid mintSvid(String vaultAddr, String vaultToken, String spiffeId, String ttl) throws Exception {
        String payload = mapper.createObjectNode()
                .put("common_name", "legacy-app.lab")
                .put("uri_sans", spiffeId)
                .put("ttl", ttl)
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

    private void logSvidMetadata(String label, String pem) throws Exception {
        List<X509Certificate> certs = parseCertificates(pem);
        if (certs.isEmpty()) {
            return;
        }
        X509Certificate cert = certs.get(0);
        Instant now = Instant.now();
        Instant notAfter = cert.getNotAfter().toInstant();
        long secondsLeft = Duration.between(now, notAfter).getSeconds();
        System.out.println(label + " expires at " + cert.getNotAfter() + " (in " + secondsLeft + "s)");
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

    private String fetchKvMessage(String vaultAddr, String vaultToken, String kvPath) throws Exception {
        String normalizedPath = kvPath.startsWith("/") ? kvPath.substring(1) : kvPath;
        HttpRequest request = HttpRequest.newBuilder(URI.create(vaultAddr + "/v1/" + normalizedPath))
                .timeout(Duration.ofSeconds(10))
                .header("X-Vault-Token", vaultToken)
                .GET()
                .build();

        HttpResponse<String> response = unauthenticatedClient().send(request, HttpResponse.BodyHandlers.ofString());
        ensureSuccess(response, "Vault KV v2 read");

        JsonNode data = mapper.readTree(response.body()).path("data").path("data");
        JsonNode message = data.path("message");
        if (message.isMissingNode() || message.asText().isBlank()) {
            return null;
        }
        return message.asText();
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

    private void logTrustBundle(String label, String pem) throws Exception {
        if (pem == null || pem.isBlank()) {
            System.out.println(label + ": (not provided)");
            return;
        }
        List<X509Certificate> certs = parseCertificates(pem);
        for (int i = 0; i < certs.size(); i++) {
            X509Certificate cert = certs.get(i);
            String cn = cert.getSubjectX500Principal().getName();
            String fp = sha256Fingerprint(cert);
            System.out.println(label + " cert[" + i + "]: " + cn + " sha256=" + fp);
        }
    }

    private String sha256Fingerprint(X509Certificate cert) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(cert.getEncoded());
        StringBuilder sb = new StringBuilder(hash.length * 3 - 1);
        for (int i = 0; i < hash.length; i++) {
            if (i > 0) {
                sb.append(':');
            }
            sb.append(String.format("%02X", hash[i]));
        }
        return sb.toString();
    }

    private record IssuedSvid(String certificate, String privateKey, String issuingCa) {
    }
}
