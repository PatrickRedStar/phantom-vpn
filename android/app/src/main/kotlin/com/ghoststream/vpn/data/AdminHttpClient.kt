package com.ghoststream.vpn.data

import okhttp3.OkHttpClient
import java.io.File
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.CertificateException

/**
 * OkHttp client factory for mTLS admin API calls.
 *
 * Builds a client that:
 *  - presents the profile's client cert/key (from PEM files)
 *  - pins the admin-server cert by SHA-256 (TOFU: pin on first handshake).
 *  - disables hostname verification (server cert CN = 10.7.0.1).
 */
object AdminHttpClient {

    data class HandshakeOutcome(
        val client: OkHttpClient,
        /** SHA-256 hex of the server leaf cert observed during the last handshake. Null until first request. */
        val serverCertFpRef: ServerCertFpRef,
    )

    class ServerCertFpRef {
        @Volatile var value: String? = null
    }

    fun build(
        certPemPath: String,
        keyPemPath: String,
        pinnedFp: String?,
    ): HandshakeOutcome {
        val certPem = File(certPemPath).readText()
        val keyPem = File(keyPemPath).readText()

        val clientCerts = parsePemCertChain(certPem)
        val clientKey = parsePemPrivateKey(keyPem)

        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry("client", clientKey, CharArray(0), clientCerts.toTypedArray())
        }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
            init(keyStore, CharArray(0))
        }

        val seenRef = ServerCertFpRef()

        val pinningTm = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) {}

            override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
                if (chain.isEmpty()) throw CertificateException("empty server chain")
                val fp = sha256Hex(chain[0].encoded)
                seenRef.value = fp
                if (pinnedFp != null && !fp.equals(pinnedFp, ignoreCase = true)) {
                    throw CertificateException(
                        "admin server cert pin mismatch: expected $pinnedFp, got $fp",
                    )
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }

        val sslCtx = SSLContext.getInstance("TLS").apply {
            init(kmf.keyManagers, arrayOf<TrustManager>(pinningTm), null)
        }

        val client = OkHttpClient.Builder()
            .sslSocketFactory(sslCtx.socketFactory, pinningTm)
            .hostnameVerifier(HostnameVerifier { _, _ -> true })
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()

        return HandshakeOutcome(client = client, serverCertFpRef = seenRef)
    }

    fun sha256Hex(data: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        val d = md.digest(data)
        val sb = StringBuilder(d.size * 2)
        for (b in d) sb.append(String.format("%02x", b.toInt() and 0xff))
        return sb.toString()
    }

    private fun parsePemCertChain(pem: String): List<X509Certificate> {
        val cf = CertificateFactory.getInstance("X.509")
        val out = mutableListOf<X509Certificate>()
        val regex = Regex(
            "-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----",
            RegexOption.DOT_MATCHES_ALL,
        )
        for (m in regex.findAll(pem)) {
            val b64 = m.groupValues[1].replace("\\s".toRegex(), "")
            val der = Base64.getDecoder().decode(b64)
            out.add(cf.generateCertificate(der.inputStream()) as X509Certificate)
        }
        if (out.isEmpty()) error("no CERTIFICATE block in PEM")
        return out
    }

    private fun parsePemPrivateKey(pem: String): PrivateKey {
        val cleaned = pem
            .replace(Regex("-----BEGIN [A-Z ]*PRIVATE KEY-----"), "")
            .replace(Regex("-----END [A-Z ]*PRIVATE KEY-----"), "")
            .replace("\\s".toRegex(), "")
        val der = Base64.getDecoder().decode(cleaned)
        val spec = PKCS8EncodedKeySpec(der)
        val algos = listOf("Ed25519", "EC", "RSA")
        for (alg in algos) {
            runCatching {
                return KeyFactory.getInstance(alg).generatePrivate(spec)
            }
        }
        error("unsupported private key algorithm")
    }
}
