package ca.openphotos.android.ui;

import android.animation.ObjectAnimator;
import android.content.Intent;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import ca.openphotos.android.R;
import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.ServerPhotosService;
import com.bumptech.glide.Glide;
import com.bumptech.glide.load.DataSource;
import com.bumptech.glide.load.engine.GlideException;
import com.bumptech.glide.load.model.GlideUrl;
import com.bumptech.glide.load.model.LazyHeaders;
import com.bumptech.glide.request.RequestListener;
import com.bumptech.glide.request.target.Target;
import com.google.android.material.button.MaterialButton;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * Full-screen slideshow activity for server photos.
 *
 * Features:
 * - Crossfade transitions between photos (600ms duration)
 * - Auto-advance with configurable timing (3s/5s/10s)
 * - Tap to pause/resume playback
 * - Swipe left/right for manual navigation
 * - Auto-hide controls after 3 seconds of inactivity
 * - Loops at the end
 * - Keeps screen awake during playback
 *
 * Usage:
 * Intent intent = new Intent(context, SlideshowActivity.class);
 * intent.putStringArrayListExtra("asset_ids", assetIdsList);
 * intent.putIntExtra("start_index", 0);
 * startActivity(intent);
 */
public class SlideshowActivity extends AppCompatActivity {
    // Keep slideshow controls visible to ensure Close/Pause are always reachable.
    private static final boolean AUTO_HIDE_CONTROLS = false;
    // Data
    private List<String> assetIds = new ArrayList<>();
    private int currentIndex = 0;

    // Playback state
    private boolean isPlaying = true;
    private int slideDuration = 5000; // milliseconds (3s/5s/10s)
    private Handler handler = new Handler(Looper.getMainLooper());
    private Runnable advanceRunnable;
    private Runnable hideControlsRunnable;

    // UI elements
    private ImageView imageCurrent;
    private ImageView imageNext;
    private ProgressBar progress;
    private View controlBar;
    private ImageButton btnClose;
    private MaterialButton btnSpeed;
    private TextView textCounter;
    private ImageView iconPlayPause;
    private TextView textStatus;
    private View rootContainer;

    // Gesture handling
    private GestureDetector gestureDetector;

    // Image loading
    private ServerPhotosService photoService;
    private String authToken;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Keep screen awake during slideshow
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        // Immersive fullscreen mode
        enableImmersiveMode();

        setContentView(R.layout.activity_slideshow);

        // Initialize services
        photoService = new ServerPhotosService(this);
        authToken = AuthManager.get(this).getToken();

        // Get data from intent
        Intent intent = getIntent();
        ArrayList<String> ids = intent.getStringArrayListExtra("asset_ids");
        if (ids != null && !ids.isEmpty()) {
            assetIds = ids;
            currentIndex = intent.getIntExtra("start_index", 0);
        } else {
            Toast.makeText(this, "No photos to display", Toast.LENGTH_SHORT).show();
            finish();
            return;
        }

        // Initialize UI
        initViews();
        setupGestures();
        setupControls();
        showControls();

        // Load initial image and start slideshow
        loadCurrentImage();
        if (isPlaying) {
            scheduleAdvance();
        }

        // Auto-hide controls
        if (isPlaying) scheduleControlsHide();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        // Cleanup: stop timers and clear screen-awake flag
        cancelAdvance();
        cancelControlsHide();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    @Override
    protected void onResume() {
        super.onResume();
        enableImmersiveMode();
    }

    /**
     * Enable immersive fullscreen mode (hide status bar and navigation bar).
     */
    private void enableImmersiveMode() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        );
    }

    /**
     * Initialize all view references.
     */
    private void initViews() {
        imageCurrent = findViewById(R.id.image_current);
        imageNext = findViewById(R.id.image_next);
        progress = findViewById(R.id.progress);
        controlBar = findViewById(R.id.control_bar);
        btnClose = findViewById(R.id.btn_close);
        btnSpeed = findViewById(R.id.btn_speed);
        textCounter = findViewById(R.id.text_counter);
        iconPlayPause = findViewById(R.id.icon_play_pause);
        textStatus = findViewById(R.id.text_status);
        rootContainer = findViewById(R.id.root_container);

        updateCounter();
        updatePlayPauseIndicator();
        updateSpeedButton();
    }

    /**
     * Setup gesture detector for tap and swipe.
     */
    private void setupGestures() {
        gestureDetector = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            @Override
            public boolean onDown(MotionEvent e) {
                // Required so single-tap/fling callbacks continue to fire reliably.
                return true;
            }

            @Override
            public boolean onSingleTapConfirmed(MotionEvent e) {
                handleTap();
                return true;
            }

            @Override
            public boolean onFling(MotionEvent e1, MotionEvent e2, float velocityX, float velocityY) {
                float deltaX = e2.getX() - e1.getX();
                float deltaY = e2.getY() - e1.getY();

                // Horizontal swipe for navigation (threshold: 50dp)
                if (Math.abs(deltaX) > Math.abs(deltaY) && Math.abs(deltaX) > 50 * getResources().getDisplayMetrics().density) {
                    if (deltaX < 0) {
                        // Swipe left: next photo
                        goToNext();
                    } else {
                        // Swipe right: previous photo
                        goToPrevious();
                    }
                    showControls();
                    scheduleControlsHide();
                    return true;
                }
                return false;
            }
        });

        rootContainer.setOnTouchListener((v, event) -> gestureDetector.onTouchEvent(event));
    }

    /**
     * Setup control button click listeners.
     */
    private void setupControls() {
        btnClose.setOnClickListener(v -> finish());

        View.OnClickListener togglePlayback = v -> {
            togglePlayPause();
            showControls();
            scheduleControlsHide();
        };
        iconPlayPause.setOnClickListener(togglePlayback);
        textStatus.setOnClickListener(togglePlayback);

        btnSpeed.setOnClickListener(v -> {
            // Cycle through 3s → 5s → 10s
            if (slideDuration == 3000) {
                slideDuration = 5000;
            } else if (slideDuration == 5000) {
                slideDuration = 10000;
            } else {
                slideDuration = 3000;
            }

            updateSpeedButton();
            Toast.makeText(this, "Speed: " + (slideDuration / 1000) + "s", Toast.LENGTH_SHORT).show();

            // Restart timer with new duration if playing
            if (isPlaying) {
                cancelAdvance();
                scheduleAdvance();
            }

            // Keep controls visible briefly
            showControls();
            scheduleControlsHide();
        });
    }

    /**
     * Handle tap gesture: toggle play/pause.
     */
    private void handleTap() {
        togglePlayPause();
        showControls();
        scheduleControlsHide();
    }

    /**
     * Toggle play/pause state.
     */
    private void togglePlayPause() {
        isPlaying = !isPlaying;

        if (isPlaying) {
            scheduleAdvance();
            scheduleControlsHide();
        } else {
            cancelAdvance();
            // Keep controls visible while paused so Close/Play are always reachable.
            cancelControlsHide();
            showControls();
        }

        updatePlayPauseIndicator();
    }

    /**
     * Update play/pause indicator icon and text.
     */
    private void updatePlayPauseIndicator() {
        if (isPlaying) {
            // While playing, show pause glyph as the available action.
            iconPlayPause.setImageResource(android.R.drawable.ic_media_pause);
            textStatus.setText("Playing");
        } else {
            // While paused, show play glyph as the available action.
            iconPlayPause.setImageResource(android.R.drawable.ic_media_play);
            textStatus.setText("Paused");
        }
    }

    /**
     * Update speed button text.
     */
    private void updateSpeedButton() {
        btnSpeed.setText((slideDuration / 1000) + "s");
    }

    /**
     * Update photo counter text.
     */
    private void updateCounter() {
        textCounter.setText((currentIndex + 1) + " / " + assetIds.size());
    }

    /**
     * Show control bar.
     */
    private void showControls() {
        controlBar.animate().cancel();
        controlBar.setAlpha(1f);
        controlBar.setVisibility(View.VISIBLE);
    }

    /**
     * Hide control bar with fade-out animation.
     */
    private void hideControls() {
        if (!AUTO_HIDE_CONTROLS) return;
        if (!isPlaying || controlBar.getVisibility() != View.VISIBLE) return;
        controlBar.animate().cancel();
        ObjectAnimator.ofFloat(controlBar, "alpha", 1f, 0f)
                .setDuration(300)
                .start();
        controlBar.postDelayed(() -> controlBar.setVisibility(View.GONE), 300);
    }

    /**
     * Schedule auto-hide of controls after 3 seconds.
     */
    private void scheduleControlsHide() {
        if (!AUTO_HIDE_CONTROLS) return;
        if (!isPlaying) return;
        cancelControlsHide();
        hideControlsRunnable = this::hideControls;
        handler.postDelayed(hideControlsRunnable, 3000);
    }

    /**
     * Cancel scheduled control hide.
     */
    private void cancelControlsHide() {
        if (hideControlsRunnable != null) {
            handler.removeCallbacks(hideControlsRunnable);
            hideControlsRunnable = null;
        }
    }

    /**
     * Load the current photo into imageCurrent.
     */
    private void loadCurrentImage() {
        if (assetIds.isEmpty() || currentIndex < 0 || currentIndex >= assetIds.size()) {
            return;
        }

        String assetId = assetIds.get(currentIndex);
        String imageUrl = photoService.imageUrl(assetId);

        progress.setVisibility(View.VISIBLE);

        // Build Glide request with authorization header
        Object model = authToken != null && !authToken.isEmpty()
                ? new GlideUrl(imageUrl, new LazyHeaders.Builder()
                .addHeader("Authorization", "Bearer " + authToken)
                .build())
                : imageUrl;

        Glide.with(this)
                .load(model)
                .listener(new RequestListener<Drawable>() {
                    @Override
                    public boolean onLoadFailed(@Nullable GlideException e, Object model, Target<Drawable> target, boolean isFirstResource) {
                        progress.setVisibility(View.GONE);
                        return false;
                    }

                    @Override
                    public boolean onResourceReady(Drawable resource, Object model, Target<Drawable> target, DataSource dataSource, boolean isFirstResource) {
                        progress.setVisibility(View.GONE);
                        // Preload next images
                        prefetchAdjacentImages();
                        return false;
                    }
                })
                .into(imageCurrent);

        updateCounter();
    }

    /**
     * Preload adjacent images (next and next+1) for smooth transitions.
     */
    private void prefetchAdjacentImages() {
        // Preload next
        int nextIdx = (currentIndex + 1) % assetIds.size();
        prefetchImage(nextIdx);

        // Preload next+1
        int next2Idx = (currentIndex + 2) % assetIds.size();
        prefetchImage(next2Idx);
    }

    /**
     * Prefetch a single image by index.
     */
    private void prefetchImage(int index) {
        if (index < 0 || index >= assetIds.size()) return;

        String assetId = assetIds.get(index);
        String imageUrl = photoService.imageUrl(assetId);

        Object model = authToken != null && !authToken.isEmpty()
                ? new GlideUrl(imageUrl, new LazyHeaders.Builder()
                .addHeader("Authorization", "Bearer " + authToken)
                .build())
                : imageUrl;

        Glide.with(this).load(model).preload();
    }

    /**
     * Advance to next photo with crossfade animation.
     */
    private void advanceToNext() {
        if (assetIds.isEmpty()) return;

        // Calculate next index (loop at end)
        int nextIdx = (currentIndex + 1) % assetIds.size();
        String nextAssetId = assetIds.get(nextIdx);
        String nextImageUrl = photoService.imageUrl(nextAssetId);

        // Load next image into imageNext layer
        Object model = authToken != null && !authToken.isEmpty()
                ? new GlideUrl(nextImageUrl, new LazyHeaders.Builder()
                .addHeader("Authorization", "Bearer " + authToken)
                .build())
                : nextImageUrl;

        Glide.with(this)
                .load(model)
                .listener(new RequestListener<Drawable>() {
                    @Override
                    public boolean onLoadFailed(@Nullable GlideException e, Object model, Target<Drawable> target, boolean isFirstResource) {
                        // On failure, skip to next
                        currentIndex = nextIdx;
                        loadCurrentImage();
                        if (isPlaying) scheduleAdvance();
                        return false;
                    }

                    @Override
                    public boolean onResourceReady(Drawable resource, Object model, Target<Drawable> target, DataSource dataSource, boolean isFirstResource) {
                        // Perform crossfade animation
                        performCrossfade(nextIdx);
                        return false;
                    }
                })
                .into(imageNext);
    }

    /**
     * Perform crossfade animation between current and next image layers.
     */
    private void performCrossfade(int nextIdx) {
        // Ensure next image is actually loaded before starting crossfade
        if (imageNext.getDrawable() == null) {
            // Fallback: just swap without animation if image not loaded
            currentIndex = nextIdx;
            loadCurrentImage();
            if (isPlaying) {
                scheduleAdvance();
            }
            return;
        }

        // Crossfade animation: fade out current, fade in next (600ms)
        ObjectAnimator fadeOut = ObjectAnimator.ofFloat(imageCurrent, "alpha", 1f, 0f);
        fadeOut.setDuration(600);

        ObjectAnimator fadeIn = ObjectAnimator.ofFloat(imageNext, "alpha", 0f, 1f);
        fadeIn.setDuration(600);

        // Use AnimatorSet to ensure synchronized playback
        android.animation.AnimatorSet animatorSet = new android.animation.AnimatorSet();
        animatorSet.playTogether(fadeOut, fadeIn);
        animatorSet.addListener(new android.animation.AnimatorListenerAdapter() {
            @Override
            public void onAnimationEnd(android.animation.Animator animation) {
                // After animation completes, swap layers and reset
                // Swap: copy next drawable to current, reset next
                Drawable nextDrawable = imageNext.getDrawable();
                if (nextDrawable != null) {
                    imageCurrent.setImageDrawable(nextDrawable);
                }
                imageCurrent.setAlpha(1f);

                imageNext.setImageDrawable(null);
                imageNext.setAlpha(0f);

                // Update index
                currentIndex = nextIdx;
                updateCounter();

                // Prefetch next images
                prefetchAdjacentImages();

                // Schedule next advance if playing
                if (isPlaying) {
                    scheduleAdvance();
                }
            }
        });
        animatorSet.start();
    }

    /**
     * Go to previous photo (manual navigation, no crossfade).
     */
    private void goToPrevious() {
        if (assetIds.isEmpty()) return;

        // Calculate previous index (loop at beginning)
        currentIndex = currentIndex == 0 ? assetIds.size() - 1 : currentIndex - 1;

        // Reset layers
        imageNext.setImageDrawable(null);
        imageNext.setAlpha(0f);

        // Load new current image
        loadCurrentImage();

        // Restart timer if playing
        if (isPlaying) {
            cancelAdvance();
            scheduleAdvance();
        }
    }

    /**
     * Go to next photo (manual navigation).
     */
    private void goToNext() {
        // Stop current timer
        cancelAdvance();

        // Advance immediately
        advanceToNext();

        // Note: scheduleAdvance is called in performCrossfade after animation completes
    }

    /**
     * Schedule auto-advance based on current slide duration.
     */
    private void scheduleAdvance() {
        cancelAdvance();
        advanceRunnable = this::advanceToNext;
        handler.postDelayed(advanceRunnable, slideDuration);
    }

    /**
     * Cancel scheduled advance.
     */
    private void cancelAdvance() {
        if (advanceRunnable != null) {
            handler.removeCallbacks(advanceRunnable);
            advanceRunnable = null;
        }
    }
}
