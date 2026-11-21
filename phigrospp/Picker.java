package phigrospp;

import android.app.Activity;
import android.app.Application;
import android.app.Fragment;
import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;

// android's file picker only answers an Activity or a Fragment, so phigrospp.pick (engine.lua) loads this one from the
// bundle's picker.dex: it opens the picker and keeps the picked file for lua to take once done is set
@SuppressWarnings("deprecation") // androidx fragments would need the game's activity to be one of theirs
public class Picker extends Fragment implements Application.ActivityLifecycleCallbacks {
  static final int CAP = 32 << 20;
  static String[] types;
  public static byte[] data; // null when the player backed out or the file can't be read
  public static String name; // the file's name, or why it can't be read
  public static volatile boolean done;

  public static void pick(Activity activity, String[] mimeTypes) {
    types = mimeTypes;
    data = null;
    name = null;
    done = false;
    activity.getFragmentManager().beginTransaction().add(new Picker(), null).commit();
  }

  @Override
  public void onCreate(Bundle state) {
    super.onCreate(state);
    getActivity().getApplication().registerActivityLifecycleCallbacks(this);
    startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        .putExtra(Intent.EXTRA_MIME_TYPES, types), 0);
  }

  @Override
  public void onActivityResult(int request, int result, Intent answer) {
    ContentResolver resolver = getActivity().getContentResolver();
    getActivity().getApplication().unregisterActivityLifecycleCallbacks(this);
    getFragmentManager().beginTransaction().remove(this).commitAllowingStateLoss();
    // a file of a cloud provider downloads as it's read, too slow for the thread drawing the app
    new Thread(() -> {
      if (answer != null) read(resolver, answer.getData());
      done = true;
    }).start();
  }

  static void read(ContentResolver resolver, Uri file) {
    try (Cursor cursor = resolver.query(file, null, null, null, null); InputStream in = resolver.openInputStream(file)) {
      cursor.moveToFirst();
      String title = cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME));
      ByteArrayOutputStream bytes = new ByteArrayOutputStream();
      byte[] buffer = new byte[65536];
      for (int n; bytes.size() <= CAP && (n = in.read(buffer)) > 0;) bytes.write(buffer, 0, n);
      if (bytes.size() > CAP) throw new Exception("it's bigger than 32 MB");
      data = bytes.toByteArray();
      name = title;
    } catch (Exception e) {
      name = e.getMessage();
    }
  }

  // the game's class loader doesn't know this class: a saved Fragment would crash the app when android restores it
  // after killing it behind the picker
  @Override
  public void onActivitySaveInstanceState(Activity activity, Bundle state) {
    state.remove("android:fragments");
  }

  @Override
  public void onActivityCreated(Activity activity, Bundle state) {}

  @Override
  public void onActivityStarted(Activity activity) {}

  @Override
  public void onActivityResumed(Activity activity) {}

  @Override
  public void onActivityPaused(Activity activity) {}

  @Override
  public void onActivityStopped(Activity activity) {}

  @Override
  public void onActivityDestroyed(Activity activity) {}
}
