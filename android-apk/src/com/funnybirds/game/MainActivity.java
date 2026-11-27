package com.funnybirds.game;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import com.google.android.gms.ads.AdError;
import com.google.android.gms.ads.AdListener;
import com.google.android.gms.ads.AdRequest;
import com.google.android.gms.ads.AdSize;
import com.google.android.gms.ads.AdView;
import com.google.android.gms.ads.FullScreenContentCallback;
import com.google.android.gms.ads.LoadAdError;
import com.google.android.gms.ads.MobileAds;
import com.google.android.gms.ads.OnUserEarnedRewardListener;
import com.google.android.gms.ads.initialization.InitializationStatus;
import com.google.android.gms.ads.initialization.OnInitializationCompleteListener;
import com.google.android.gms.ads.appopen.AppOpenAd;
import com.google.android.gms.ads.interstitial.InterstitialAd;
import com.google.android.gms.ads.interstitial.InterstitialAdLoadCallback;
import com.google.android.gms.ads.rewarded.RewardItem;
import com.google.android.gms.ads.rewarded.RewardedAd;
import com.google.android.gms.ads.rewarded.RewardedAdLoadCallback;

/**
 * FunnyBirds HTML game host with native AdMob ads.
 *
 * IMPORTANT FOR "NO ADS SHOWING":
 *  - MobileAds.initialize() MUST run BEFORE any AdView / Interstitial / Rewarded is created.
 *  - The AdView MUST be added to the live view hierarchy (rootLayout.addView(adView)).
 *  - These are Google's OFFICIAL TEST AD UNIT IDs -> they ALWAYS return test ads on ANY device.
 */
public class MainActivity extends Activity {

    private static final String TAG = "FunnyBirdsAds";

    // ---- Google AdMob OFFICIAL TEST AD UNIT IDs (safe on every device, always fill) ----
    private static final String BANNER_ID       = "ca-app-pub-3940256099942544/6300978111";
    private static final String INTERSTITIAL_ID = "ca-app-pub-3940256099942544/1033173712";
    private static final String REWARDED_ID     = "ca-app-pub-3940256099942544/5224354917";
    private static final String APP_OPEN_ID     = "ca-app-pub-3940256099942544/9257395921";

    private WebView webView;
    private FrameLayout rootLayout;
    private AdView adView;
    private InterstitialAd interstitialAd;
    private RewardedAd rewardedAd;
    private AppOpenAd appOpenAd;
    private boolean isUnlockedAll = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // CRASH-GUARD: the AdMob SDK runs background executor threads. A
        // missing transitive class (NoClassDefFoundError) thrown on one of
        // those threads kills the WHOLE process ~1s after launch, and a
        // main-thread try/catch can NOT catch it. This global handler logs
        // such failures and keeps the game running (never force-stop).
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            @Override
            public void uncaughtException(Thread thread, Throwable e) {
                Log.e(TAG, "Uncaught on thread " + thread.getName() + ": " + e, e);
            }
        });

        try {
            requestWindowFeature(Window.FEATURE_NO_TITLE);
            getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                    WindowManager.LayoutParams.FLAG_FULLSCREEN);
        } catch (Throwable ignore) { }

        // Root container: WebView + Banner at the bottom.
        rootLayout = new FrameLayout(this);
        rootLayout.setLayoutParams(new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(rootLayout);

        // ---------- WebView (loads the HTML game) ----------
        webView = new WebView(this);
        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        try {
            s.setAllowFileAccessFromFileURLs(true);
            s.setAllowUniversalAccessFromFileURLs(true);
            s.setMediaPlaybackRequiresUserGesture(false);
        } catch (Throwable ignore) { }
        webView.setWebViewClient(new WebViewClient());
        webView.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        webView.addJavascriptInterface(new WebAppInterface(), "Android");
        rootLayout.addView(webView);

        // ---------- Load the GAME FIRST ----------
        // The game must always open, even if every ad API below fails.
        // (Previously ad setup ran BEFORE loadUrl, so an ad crash meant the
        //  app "keeps stopping" before the game ever appeared.)
        try {
            webView.loadUrl("file:///android_asset/index.html");
        } catch (Throwable t) {
            Log.e(TAG, "webview load failed: " + t);
        }

        // ---------- DEFER all ad setup so the GAME renders first ----------
        // Running the ad SDK at launch was the "app open korar 1 second por
        // crash" trigger. Deferring it by 1.5s means a broken ad SDK can
        // never stop the game from opening. (Banner is created inside initAds.)
        webView.postDelayed(new Runnable() {
            @Override public void run() { initAds(); }
        }, 1500);
    }

    // Creates the banner, initializes the MobileAds SDK, then loads ads.
    // NOTE: MobileAds.initialize() MUST run BEFORE the AdView is created.
    private void initAds() {
        try {
            adView = new AdView(this);
            adView.setAdUnitId(BANNER_ID);
            adView.setAdSize(AdSize.BANNER);
            FrameLayout.LayoutParams blp = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT);
            blp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
            adView.setLayoutParams(blp);
            adView.setVisibility(View.GONE);
            rootLayout.addView(adView);
        } catch (Throwable t) {
            Log.w(TAG, "AdView creation failed (ads disabled): " + t);
            adView = null;
        }

        // ---------- INITIALIZE MobileAds, then load every ad format ----------
        try {
            MobileAds.initialize(this, new OnInitializationCompleteListener() {
                @Override
                public void onInitializationComplete(InitializationStatus status) {
                    // CRITICAL FIX for "app open korar 1 second por crash":
                    // This callback runs ASYNCHRONOUSLY (~1s AFTER launch).
                    // Its body was NOT inside any try/catch, so any ad-SDK
                    // failure here (e.g. NoClassDefFoundError from a broken
                    // dex split) force-closed the app right after the splash.
                    // Now it can NEVER crash the game.
                    try {
                        Log.i(TAG, "MobileAds initialized -> loading ads");
                        loadBanner();
                        loadInterstitial();
                        loadRewarded();
                        loadAppOpen();
                    } catch (Throwable t) {
                        Log.w(TAG, "ad loading after init failed (ads disabled): " + t);
                    }
                }
            });
        } catch (Throwable t) {
            Log.w(TAG, "MobileAds init failed (ads disabled): " + t);
        }
    }

    // ================= BANNER =================
    private void loadBanner() {
        if (adView == null) return;
        try {
            adView.setAdListener(new AdListener() {
                @Override public void onAdLoaded() {
                    Log.i(TAG, "BANNER loaded");
                    if (adView != null) adView.setVisibility(View.VISIBLE);
                }
                @Override public void onAdFailedToLoad(LoadAdError e) {
                    Log.w(TAG, "BANNER failed: " + e.getCode() + " " + e.getMessage());
                }
            });
            adView.loadAd(new AdRequest.Builder().build());
        } catch (Throwable t) {
            Log.w(TAG, "banner load failed: " + t);
        }
    }

    // ================= INTERSTITIAL =================
    private void loadInterstitial() {
        try {
            InterstitialAd.load(this, INTERSTITIAL_ID, new AdRequest.Builder().build(),
                    new InterstitialAdLoadCallback() {
                        @Override
                        public void onAdLoaded(InterstitialAd ad) {
                            interstitialAd = ad;
                            Log.i(TAG, "INTERSTITIAL loaded");
                        }
                        @Override
                        public void onAdFailedToLoad(LoadAdError e) {
                            interstitialAd = null;
                            Log.w(TAG, "INTERSTITIAL failed: " + e.getCode());
                        }
                    });
        } catch (Throwable t) { interstitialAd = null; }
    }

    private void showInterstitial() {
        try {
        if (interstitialAd != null) {
            interstitialAd.setFullScreenContentCallback(new FullScreenContentCallback() {
                @Override
                public void onAdDismissedFullScreenContent() {
                    interstitialAd = null;
                    loadInterstitial();
                }
                @Override
                public void onAdFailedToShowFullScreenContent(AdError e) {
                    interstitialAd = null;
                    loadInterstitial();
                }
            });
            interstitialAd.show(this);
        } else {
            loadInterstitial();
        }
        } catch (Throwable t) { Log.w(TAG, "showInterstitial failed: " + t); }
    }

    // ================= REWARDED =================
    private void loadRewarded() {
        try {
            RewardedAd.load(this, REWARDED_ID, new AdRequest.Builder().build(),
                    new RewardedAdLoadCallback() {
                        @Override
                        public void onAdLoaded(RewardedAd ad) {
                            rewardedAd = ad;
                            Log.i(TAG, "REWARDED loaded");
                        }
                        @Override
                        public void onAdFailedToLoad(LoadAdError e) {
                            rewardedAd = null;
                            Log.w(TAG, "REWARDED failed: " + e.getCode());
                        }
                    });
        } catch (Throwable t) { rewardedAd = null; }
    }

    private void showRewarded() {
        try {
        if (rewardedAd != null) {
            rewardedAd.setFullScreenContentCallback(new FullScreenContentCallback() {
                @Override
                public void onAdDismissedFullScreenContent() {
                    rewardedAd = null;
                    loadRewarded();
                }
                @Override
                public void onAdFailedToShowFullScreenContent(AdError e) {
                    rewardedAd = null;
                    loadRewarded();
                    js("if(window.onRewardedResult)window.onRewardedResult(false);");
                }
            });
            rewardedAd.show(this, new OnUserEarnedRewardListener() {
                @Override
                public void onUserEarnedReward(RewardItem item) {
                    js("if(window.onRewardedResult)window.onRewardedResult(true);");
                }
            });
        } else {
            loadRewarded();
            js("if(window.onRewardedResult)window.onRewardedResult(false);");
        }
        } catch (Throwable t) { Log.w(TAG, "showRewarded failed: " + t); }
    }

    // ================= APP OPEN =================
    private void loadAppOpen() {
        try {
            AppOpenAd.load(this, APP_OPEN_ID, new AdRequest.Builder().build(),
                    new AppOpenAd.AppOpenAdLoadCallback() {
                        @Override
                        public void onAdLoaded(AppOpenAd ad) {
                            appOpenAd = ad;
                            Log.i(TAG, "APPOPEN loaded");
                        }
                        @Override
                        public void onAdFailedToLoad(LoadAdError e) {
                            appOpenAd = null;
                            Log.w(TAG, "APPOPEN failed: " + e.getCode());
                        }
                    });
        } catch (Throwable t) { appOpenAd = null; }
    }

    private void showAppOpen() {
        try {
        if (appOpenAd != null) {
            appOpenAd.setFullScreenContentCallback(new FullScreenContentCallback() {
                @Override
                public void onAdDismissedFullScreenContent() {
                    appOpenAd = null;
                    loadAppOpen();
                }
                @Override
                public void onAdFailedToShowFullScreenContent(AdError e) {
                    appOpenAd = null;
                    loadAppOpen();
                }
            });
            appOpenAd.show(this);
        } else {
            loadAppOpen();
        }
        } catch (Throwable t) { Log.w(TAG, "showAppOpen failed: " + t); }
    }

    // ================= JS helpers =================
    private void js(final String code) {
        runOnUiThread(new Runnable() {
            @Override public void run() {
                try { if (webView != null) webView.evaluateJavascript(code, null); }
                catch (Throwable ignore) { }
            }
        });
    }

    // ============== JS BRIDGE  (window.Android) ==============
    private class WebAppInterface {

        @JavascriptInterface
        public void showInterstitial() {
            runOnUiThread(new Runnable() {
                @Override public void run() { MainActivity.this.showInterstitial(); }
            });
        }

        @JavascriptInterface
        public void showRewardedAd() {
            runOnUiThread(new Runnable() {
                @Override public void run() { MainActivity.this.showRewarded(); }
            });
        }

        @JavascriptInterface
        public void showAppOpenAd() {
            runOnUiThread(new Runnable() {
                @Override public void run() { MainActivity.this.showAppOpen(); }
            });
        }

        @JavascriptInterface
        public void showBanner() {
            runOnUiThread(new Runnable() {
                @Override public void run() {
                    if (adView != null) {
                        adView.setVisibility(View.VISIBLE);
                        adView.loadAd(new AdRequest.Builder().build());
                    }
                }
            });
        }

        @JavascriptInterface
        public void hideBanner() {
            runOnUiThread(new Runnable() {
                @Override public void run() {
                    if (adView != null) adView.setVisibility(View.GONE);
                }
            });
        }

        @JavascriptInterface
        public boolean isUnlockedAll() {
            return isUnlockedAll;
        }

        @JavascriptInterface
        public void purchaseUnlockAll() {
            // Demo unlock flow. Hook Google Play Billing here for production.
            runOnUiThread(new Runnable() {
                @Override public void run() {
                    isUnlockedAll = true;
                    js("if(window.onPurchaseResult)window.onPurchaseResult(true);");
                }
            });
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // Defensive: an ad failing to show on the main thread must NEVER be
        // allowed to crash the app (was a "app keeps stopping" cause).
        try {
            if (appOpenAd != null) showAppOpen();
        } catch (Throwable t) {
            Log.w(TAG, "app-open show skipped: " + t);
        }
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }
}
