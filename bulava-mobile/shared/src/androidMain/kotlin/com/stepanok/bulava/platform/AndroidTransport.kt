package com.stepanok.bulava.platform

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/**
 * A WebSocket over TLS that trusts exactly one key: the one whose fingerprint the QR code carried.
 * No certificate authority is consulted, and none could vouch for a Mac on a home network anyway.
 * The fingerprint is checked during the TLS handshake, so nothing — not even the hello — is sent
 * to a machine that is not that Mac.
 */
class AndroidTransport : LinkTransport {
    @Volatile private var socket: WebSocket? = null
    @Volatile private var closedByUs = false

    override fun open(url: String, pin: String, listener: TransportListener) {
        val trust = PinnedTrustManager(pin)
        val tls = SSLContext.getInstance("TLSv1.3").apply { init(null, arrayOf(trust), null) }
        val client = OkHttpClient.Builder()
            .sslSocketFactory(tls.socketFactory, trust)
            // The name on the certificate means nothing here — the key is the identity.
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .build()
        socket = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = listener.onOpen()
            override fun onMessage(webSocket: WebSocket, text: String) = listener.onText(text)
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                listener.onClosed(if (closedByUs || code == 1000) null else "closed $code")
                client.dispatcher.executorService.shutdown()
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                listener.onClosed(t.message ?: t::class.simpleName ?: "failure")
                client.dispatcher.executorService.shutdown()
            }
        })
    }

    override fun send(text: String): Boolean = socket?.send(text) ?: false

    override fun close() {
        closedByUs = true
        socket?.close(1000, null)
    }
}

class PinnedTrustManager(private val pin: String) : X509TrustManager {
    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
        val leaf = chain.firstOrNull() ?: throw CertificateException("no certificate")
        if (fingerprint(leaf.publicKey.encoded) != pin) throw CertificateException("not the Mac this phone was paired with")
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
        throw CertificateException("client certificates are not used")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    companion object {
        /** SHA-256 of the SubjectPublicKeyInfo, base64url without padding — as the Mac computes it. */
        fun fingerprint(spki: ByteArray): String =
            Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(spki))
    }
}
