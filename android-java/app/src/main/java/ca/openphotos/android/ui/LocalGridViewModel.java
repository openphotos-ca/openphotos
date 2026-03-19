package ca.openphotos.android.ui;

import android.app.Application;
import android.database.ContentObserver;
import android.net.Uri;

import androidx.annotation.NonNull;
import androidx.lifecycle.AndroidViewModel;
import androidx.lifecycle.LiveData;
import androidx.lifecycle.MutableLiveData;

import ca.openphotos.android.media.MediaStoreScanner;

import java.util.ArrayList;
import java.util.List;

/** ViewModel backing the Local grid, observing MediaStore and exposing lightweight cells. */
public class LocalGridViewModel extends AndroidViewModel {
    private final MediaStoreScanner scanner;
    private final MutableLiveData<List<MediaGridAdapter.Cell>> cells = new MutableLiveData<>(new ArrayList<>());

    public LocalGridViewModel(@NonNull Application app) {
        super(app);
        this.scanner = new MediaStoreScanner(app);
    }

    public LiveData<List<MediaGridAdapter.Cell>> cells() { return cells; }

    public void start() {
        reload();
        scanner.startObserving(this::reload);
    }

    public void stop() { scanner.stopObserving(); }

    private void reload() {
        new Thread(() -> {
            java.util.List<ca.openphotos.android.data.db.entities.PhotoEntity> items = scanner.loadAll();
            ArrayList<MediaGridAdapter.Cell> list = new ArrayList<>();
            int i = 0;
            for (ca.openphotos.android.data.db.entities.PhotoEntity p : items) {
                String id = (p.contentId != null && !p.contentId.isEmpty()) ? p.contentId : (p.contentUri + "#" + (++i));
                list.add(new MediaGridAdapter.Cell(id, "", false, p.contentUri, p.mediaType == 1));
            }
            cells.postValue(list);
        }).start();
    }
}

