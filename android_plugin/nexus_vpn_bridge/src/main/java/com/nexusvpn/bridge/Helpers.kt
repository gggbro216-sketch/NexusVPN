package com.nexusvpn.bridge

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Wraps the app's data key with a non-exportable AES-GCM key in the Android Keystore. */
object KeystoreHelper {
    private const val ALIAS = "nexus_vpn_data_key_wrap"
    private const val PROVIDER = "AndroidKeyStore"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    /** base64(plain) -> base64(iv || ciphertext), or "" on failure. */
    fun wrap(plainB64: String): String = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ct = cipher.doFinal(Base64.decode(plainB64, Base64.DEFAULT))
        Base64.encodeToString(cipher.iv + ct, Base64.NO_WRAP)
    } catch (e: Exception) {
        ""
    }

    fun unwrap(wrappedB64: String): String = try {
        val data = Base64.decode(wrappedB64, Base64.DEFAULT)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        Base64.encodeToString(cipher.doFinal(data.copyOfRange(12, data.size)), Base64.NO_WRAP)
    } catch (e: Exception) {
        ""
    }
}

/** Launchable installed apps for per-app routing. */
object AppsHelper {
    fun listJson(context: Context): String {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val activities = pm.queryIntentActivities(intent, 0)
        val seen = HashSet<String>()
        val arr = JSONArray()
        for (ri in activities.sortedBy { it.loadLabel(pm).toString().lowercase() }) {
            val pkg = ri.activityInfo.packageName
            if (pkg == context.packageName || !seen.add(pkg)) continue
            val ai = ri.activityInfo.applicationInfo
            arr.put(JSONObject()
                .put("package", pkg)
                .put("label", ri.loadLabel(pm).toString())
                .put("system", (ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0))
        }
        return arr.toString()
    }

    fun iconPng(context: Context, pkg: String, size: Int): ByteArray = try {
        val d = context.packageManager.getApplicationIcon(pkg)
        val s = size.coerceIn(16, 192)
        val bmp = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        d.setBounds(0, 0, s, s)
        d.draw(c)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        out.toByteArray()
    } catch (e: PackageManager.NameNotFoundException) {
        ByteArray(0)
    } catch (e: Exception) {
        ByteArray(0)
    }
}

/** QR generation and decoding with ZXing (Apache-2.0). */
object QrHelper {
    fun encodePng(text: String, size: Int): ByteArray {
        val s = size.coerceIn(128, 1024)
        val hints = mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2,
            EncodeHintType.CHARACTER_SET to "UTF-8")
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, s, s, hints)
        val pixels = IntArray(s * s)
        for (y in 0 until s) for (x in 0 until s) pixels[y * s + x] = if (matrix.get(x, y)) Color.BLACK else Color.WHITE
        val bmp = Bitmap.createBitmap(pixels, s, s, Bitmap.Config.ARGB_8888)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        return out.toByteArray()
    }

    fun decode(bitmap: Bitmap): String? {
        val w = bitmap.width
        val h = bitmap.height
        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        val source = RGBLuminanceSource(w, h, pixels)
        val hints = mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)
        return try {
            MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(source)), hints).text
        } catch (e: Exception) {
            null
        }
    }
}
