package ca.openphotos.android.i18n;

import android.app.Activity;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.widget.EditText;
import android.widget.TextView;

import com.google.android.material.bottomnavigation.BottomNavigationView;
import com.google.android.material.textfield.TextInputLayout;

import ca.openphotos.android.R;

/** Best-effort localization bridge for legacy hardcoded Android views. */
public final class AndroidViewLocalizer {
    private AndroidViewLocalizer() {}

    public static void install(Activity activity) {
        View root = activity.getWindow().getDecorView();
        localize(root);
        root.getViewTreeObserver().addOnGlobalLayoutListener(new ViewTreeObserver.OnGlobalLayoutListener() {
            @Override
            public void onGlobalLayout() {
                localize(root);
            }
        });
    }

    public static void localize(View view) {
        if (view == null) return;
        localizeContentDescription(view);
        if (view instanceof TextView) {
            localizeTextView((TextView) view);
        }
        if (view instanceof TextInputLayout) {
            localizeTextInputLayout((TextInputLayout) view);
        }
        if (view instanceof BottomNavigationView) {
            localizeMenu(((BottomNavigationView) view).getMenu());
        }
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                localize(group.getChildAt(i));
            }
        }
    }

    private static void localizeTextView(TextView tv) {
        if (!(tv instanceof EditText)) {
            CharSequence text = tv.getText();
            if (text != null && text.length() > 0) {
                String source = original(tv, R.id.tag_i18n_text_source, text.toString());
                String translated = AndroidI18n.t(source);
                if (!translated.contentEquals(tv.getText())) tv.setText(translated);
            }
        }
        CharSequence hint = tv.getHint();
        if (hint != null && hint.length() > 0) {
            String source = original(tv, R.id.tag_i18n_hint_source, hint.toString());
            String translated = AndroidI18n.t(source);
            if (!translated.contentEquals(tv.getHint())) tv.setHint(translated);
        }
    }

    private static void localizeTextInputLayout(TextInputLayout til) {
        CharSequence hint = til.getHint();
        if (hint != null && hint.length() > 0) {
            String source = original(til, R.id.tag_i18n_hint_source, hint.toString());
            String translated = AndroidI18n.t(source);
            if (!translated.contentEquals(til.getHint())) til.setHint(translated);
        }
    }

    private static void localizeContentDescription(View view) {
        CharSequence value = view.getContentDescription();
        if (value != null && value.length() > 0) {
            String source = original(view, R.id.tag_i18n_content_description_source, value.toString());
            String translated = AndroidI18n.t(source);
            if (!translated.contentEquals(view.getContentDescription())) view.setContentDescription(translated);
        }
    }

    private static void localizeMenu(Menu menu) {
        if (menu == null) return;
        for (int i = 0; i < menu.size(); i++) {
            MenuItem item = menu.getItem(i);
            CharSequence title = item.getTitle();
            if (title != null && title.length() > 0) item.setTitle(AndroidI18n.t(title.toString()));
            if (item.hasSubMenu()) localizeMenu(item.getSubMenu());
        }
    }

    private static String original(View view, int tagId, String fallback) {
        Object tagged = view.getTag(tagId);
        if (tagged instanceof String) return (String) tagged;
        view.setTag(tagId, fallback);
        return fallback;
    }
}
