package ca.openphotos.android.ui.util;

import android.content.Context;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.View;

import androidx.annotation.NonNull;
import androidx.recyclerview.widget.RecyclerView;

/** Simple item click/long-click listener for RecyclerView without extra deps. */
public class RecyclerItemClickListener implements RecyclerView.OnItemTouchListener {
    public interface OnItemClickListener { void onItemClick(View view, int position); void onLongItemClick(View view, int position); }

    private final OnItemClickListener mListener;
    private final GestureDetector mGestureDetector;
    private final RecyclerView mRecyclerView;

    public RecyclerItemClickListener(Context context, RecyclerView recyclerView, OnItemClickListener listener) {
        mListener = listener; mRecyclerView = recyclerView;
        mGestureDetector = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onSingleTapUp(MotionEvent e) { return true; }
            @Override public void onLongPress(MotionEvent e) {
                View child = mRecyclerView.findChildViewUnder(e.getX(), e.getY());
                if (child != null && mListener != null) mListener.onLongItemClick(child, mRecyclerView.getChildAdapterPosition(child));
            }
        });
    }

    @Override public boolean onInterceptTouchEvent(@NonNull RecyclerView view, @NonNull MotionEvent e) {
        View child = view.findChildViewUnder(e.getX(), e.getY());
        if (child != null && mListener != null && mGestureDetector.onTouchEvent(e)) {
            mListener.onItemClick(child, view.getChildAdapterPosition(child));
            return true;
        }
        return false;
    }

    @Override public void onTouchEvent(@NonNull RecyclerView view, @NonNull MotionEvent motionEvent) { }
    @Override public void onRequestDisallowInterceptTouchEvent(boolean disallowIntercept) { }
}

