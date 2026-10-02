package com.pixeldesktop.worker;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * The one-shot Pixel compute worker.
 *
 * <p>Lifecycle (D6), deliberately bounded — no Service, no daemon, no persistent process:
 *
 * <pre>
 *   launch -> read fixed job file -> compute -> write fixed result -> finish
 * </pre>
 *
 * <p>It is launched by ADB ({@code am start}) and finishes on its own. It holds no state between
 * runs beyond the two files.
 *
 * <p><b>File identity (ADR-010 Revision 1).</b> This Activity runs under the application's own
 * UID and reads/writes its OWN app-specific external files directory. It does <em>not</em> use
 * {@code /data/local/tmp}, which is owned by {@code shell} and is not writable by an application.
 * The ADB shell UID writes the job file and reads the result file; this process reads the job and
 * writes the result. The two identities are not equivalent and neither relies on the other's
 * privileges.
 *
 * <p><b>Zero permissions.</b> Reading and writing this app's own external files directory
 * requires no Android permission.
 *
 * <p>There is no network access, no socket, no service, no shell execution and no dynamic code
 * loading in this class.
 */
public class WorkerActivity extends Activity {

    private static final String TAG = "PixelDesktopWorker";

    /** Fixed filenames. No caller may influence these; they are constants (ADR-010). */
    static final String JOB_FILE = "job.json";
    static final String RESULT_FILE = "result.json";

    /** Bound on the job file we are willing to read, in bytes. */
    private static final long MAX_JOB_BYTES = 1_048_576L;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // CONTAINMENT for an exported Activity: verify who launched us.
        //
        // The Activity must be exported for ADB to start it (see the manifest), so this check
        // restricts who can actually trigger a run.
        //
        // MEASURED, not assumed: `am start` from adb reports `getLaunchedFromUid() == -1`, NOT
        // 2000. The first build rejected -1 and refused every legitimate adb launch. -1 is
        // Android's sentinel for "unknown/absent launcher", and it is what the documented ADB
        // launch path produces.
        //
        // Accepted: -1 (adb / unknown), 0 (root), 2000 (shell).
        // Rejected: any other concrete UID, i.e. another application.
        int launchedFromUid = getLaunchedFromUid();
        Log.i(TAG, "WORKER_LAUNCHER uid=" + launchedFromUid
                + " own_uid=" + android.os.Process.myUid());

        boolean acceptableLauncher = launchedFromUid == -1
                || launchedFromUid == 0
                || launchedFromUid == 2000;

        if (!acceptableLauncher) {
            Log.e(TAG, "WORKER_FAILED type=UNAUTHORIZED_LAUNCHER launched_from_uid=" + launchedFromUid);
            finish();
            return;
        }

        // The app creates its OWN exchange directory. This matters: if adb creates it first, the
        // directory is owned by `shell:ext_data_rw` with mode drwxrws---, and this process (its own
        // UID, not in ext_data_rw) CANNOT WRITE IT. Measured on the real device — an adb-created
        // directory broke the worker's own access. getExternalFilesDir() creates the directory
        // owned by this app, which is the only correct owner.
        File dir = getExternalFilesDir(null);
        if (dir != null) {
            Log.i(TAG, "WORKER_WORKSPACE path=" + dir.getAbsolutePath()
                    + " created=" + dir.exists());
        }
        if (dir == null) {
            // External storage unavailable. Report and exit rather than guessing a location.
            Log.e(TAG, "WORKER_FAILED: external files directory unavailable");
            finish();
            return;
        }

        File jobFile = new File(dir, JOB_FILE);
        File resultFile = new File(dir, RESULT_FILE);

        // Announce identity and paths so the Mac can confirm which UID did the work and where.
        Log.i(TAG, "WORKER_STARTED pkg=" + getPackageName()
                + " uid=" + android.os.Process.myUid()
                + " pid=" + android.os.Process.myPid()
                + " dir=" + dir.getAbsolutePath());

        String jobId = "unknown";
        try {
            if (!jobFile.isFile()) {
                throw new Dtca1.InvalidInput("job file not found: " + jobFile.getAbsolutePath());
            }
            if (jobFile.length() > MAX_JOB_BYTES) {
                throw new Dtca1.InvalidInput("job file exceeds " + MAX_JOB_BYTES + " bytes");
            }

            String raw = readFile(jobFile);
            JSONObject job = new JSONObject(raw);

            jobId = job.optString("job_id", "unknown");
            String workload = job.optString("workload", "");
            String input = job.optString("input", "");

            JSONObject result;

            if ("DTCA-1".equals(workload)) {
                // The Phase 5 deterministic workload. Unchanged, and still independently
                // verifiable by re-computation on the Mac.
                result = Dtca1.execute(input, jobId);

            } else if (LlmWorkload.WORKLOAD_NAME.equals(workload)) {
                // Phase 6: real local language-model inference. Not recomputable on the Mac —
                // the Mac has no model and no runtime — so it is verified by an evidence chain
                // and an ablation test instead. See ADR-012 §P7.
                LlmWorkload.ensureModelDirectory(dir);
                result = LlmWorkload.execute(job, dir);

            } else {
                throw new Dtca1.InvalidInput("unsupported workload: '" + workload + "'");
            }

            writeFile(resultFile, result.toString());
            Log.i(TAG, "WORKER_RESULT_READY job_id=" + jobId
                    + " status=" + result.optString("status")
                    + " workload=" + workload
                    + " generated_tokens=" + result.optInt("generated_tokens")
                    + " duration_ms=" + result.optLong("execution_duration_ms"));

        } catch (LlmWorkload.Failure llmFailure) {
            // Bounded, machine-readable failure. The error type is a fixed token, never raw
            // native output, so a native error cannot become an unrestricted protocol.
            writeFailure(resultFile, jobId, llmFailure.errorType, llmFailure.getMessage());
            Log.e(TAG, "WORKER_FAILED job_id=" + jobId + " type=" + llmFailure.errorType
                    + " " + llmFailure.getMessage());

        } catch (Dtca1.InvalidInput invalid) {
            // Deterministic failure reporting: write a FAILED result rather than crashing, so the
            // Mac always finds a result file and never has to distinguish "no result" from
            // "crashed".
            writeFailure(resultFile, jobId, "INVALID_INPUT", invalid.getMessage());
            Log.e(TAG, "WORKER_FAILED job_id=" + jobId + " type=INVALID_INPUT " + invalid.getMessage());

        } catch (Exception unexpected) {
            writeFailure(resultFile, jobId, "EXECUTION_ERROR", String.valueOf(unexpected.getMessage()));
            Log.e(TAG, "WORKER_FAILED job_id=" + jobId + " type=EXECUTION_ERROR "
                    + unexpected.getMessage());
        }

        // One-shot: finish immediately. There is no background component and no state to keep.
        finish();
    }

    private static String readFile(File file) throws Exception {
        try (InputStream in = new FileInputStream(file)) {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            byte[] chunk = new byte[8192];
            int read;
            while ((read = in.read(chunk)) != -1) {
                buffer.write(chunk, 0, read);
            }
            return buffer.toString(StandardCharsets.UTF_8.name());
        }
    }

    private static void writeFile(File file, String content) throws Exception {
        try (OutputStream out = new FileOutputStream(file)) {
            out.write(content.getBytes(StandardCharsets.UTF_8));
        }
    }

    private void writeFailure(File resultFile, String jobId, String errorType, String message) {
        try {
            JSONObject failure = new JSONObject();
            failure.put("status", "FAILED");
            failure.put("job_id", jobId);
            failure.put("error_type", errorType);
            failure.put("error_message", message == null ? "" : message);
            writeFile(resultFile, failure.toString());
        } catch (Exception ignored) {
            // Nothing further can be done; the absence of a result is itself the signal.
        }
    }
}
