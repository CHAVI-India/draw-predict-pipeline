import os
import select
import signal
import subprocess
import logging
import time

LOG = logging.getLogger(__name__)

# Maximum number of seconds with no stdout output before a subprocess is
# considered hung and killed.  nnUNet normally prints progress at least every
# few seconds during inference and export, so 10 minutes of total silence is a
# safe threshold.  Configurable via env var.
SUBPROCESS_INACTIVITY_TIMEOUT = int(os.environ.get("NNUNET_SUBPROCESS_INACTIVITY_TIMEOUT", "600"))


class NNUNetV2Adapter:
    """
    Provides a simplified python class for using NNUNet via the CLI.
    Assumes ``nnUNet_v2`` is installed
    """

    NNUNET_RAW = "nnUNet_raw"
    NNUNET_PREPROCESSED = "nnUNet_preprocessed"
    NNUNET_RESULTS = "nnUNet_results"

    def __init__(self, raw_dir, preprocessed_dir, preds_dir):
        self.raw_dir = raw_dir
        self.preprocessed_dir = preprocessed_dir
        self.preds_dir = preds_dir
        self.num_plan_processes = 6
        self.set_env()

    def set_env(self):
        os.environ[self.NNUNET_RAW] = self.raw_dir
        os.environ[self.NNUNET_PREPROCESSED] = self.preprocessed_dir
        os.environ[self.NNUNET_RESULTS] = self.preds_dir
        os.environ["nnUNet_def_n_proc"] = "6"
        os.environ["nnUNet_n_proc_DA"] = "6"
        os.environ["nnUNet_compile"] = "0"
        os.makedirs(self.raw_dir, exist_ok=True)
        os.makedirs(self.preprocessed_dir, exist_ok=True)
        os.makedirs(self.preds_dir, exist_ok=True)

    def determine_postprocessing(self, input_folder, gt_labels_folder, dj_file, p_file):
        """
        Determine PostProcessing. Creates PKL file in input_folder. Copy these
        """
        self.set_env()
        run_args = [
            "nnUNetv2_determine_postprocessing",
            "-i",
            input_folder,
            "-ref",
            gt_labels_folder,
            "--remove_postprocessed",
            "-plans_json",
            p_file,
            "-dataset_json",
            dj_file,
        ]
        self._run_subprocess(run_args)

    def apply_postprocessing(self, input_folder, output_folder, pkl_file):
        self.set_env()
        run_args = [
            "nnUNetv2_apply_postprocessing",
            "-i",
            input_folder,
            "-o",
            output_folder,
            "-pp_pkl",
            pkl_file,
        ]
        self._run_subprocess(run_args)

    def plan(self, dataset_id: str, config: str, gpu_memory_gb: int = None):
        self.set_env()
        run_args = [
            "nnUNetv2_plan_and_preprocess",
            "-d",
            dataset_id,
            "--verify_dataset_integrity",
            "--clean",
            "-c",
            config,
            "-np",
            self.num_plan_processes,
        ]
        if gpu_memory_gb is not None:
            run_args.extend(["-gpu_memory_target", gpu_memory_gb])
        self._run_subprocess(run_args)

    def evaluate_on_folder(self, gt_dir, preds_dir, dj_file, p_file):
        self.set_env()
        run_args = [
            "nnUNetv2_evaluate_folder",
            gt_dir,
            preds_dir,
            "-djfile",
            dj_file,
            "-pfile",
            p_file,
            "--chill",
        ]
        self._run_subprocess(run_args)

    def train(
        self,
        dataset_id: str,
        model_config: str,
        fold: int,
        trainer_name: str = "nnUNetTrainer",
        resume: bool = True,
        device_id: int = 0,
    ):
        self.set_env()
        os.environ["CUDA_VISIBLE_DEVICES"] = str(device_id)
        run_args = [
            "nnUNetv2_train",
            dataset_id,
            model_config,
            fold,
            "-tr",
            trainer_name,
        ]

        if resume:
            run_args.append("--c")

        self._run_subprocess(run_args)

    def predict_folder(
        self,
        samples_dir,
        output_dir,
        model_config,
        dataset_id,
        fold,
        trainer_name="nnUNetTrainer",
        checkpoint_name="checkpoint_best.pth",
    ):
        self.set_env()
        run_args = [
            "nnUNetv2_predict",
            "-i",
            samples_dir,
            "-o",
            output_dir,
            "-c",
            model_config,
            "-d",
            dataset_id,
            "-f",
            fold,
            "-chk",
            checkpoint_name,
            "--disable_tta",
            "-device",
            "cuda",
            "-tr",
            trainer_name,
            "-npp",
            "1",
            "-nps",
            "1",
        ]
        self._run_subprocess(run_args)

    @staticmethod
    def _run_subprocess(run_args, env=None):
        """Synchronous call to nnunet, streaming stdout line-by-line so progress is logged in real time.

        Includes an inactivity timeout: if the subprocess produces no stdout
        output for ``SUBPROCESS_INACTIVITY_TIMEOUT`` seconds, it is killed and a
        ``subprocess.TimeoutExpired`` is raised.  This prevents the pipeline
        from hanging indefinitely when an nnUNet export worker is OOM-killed
        and the parent process blocks on a dead result.
        """
        run_args = [str(i) for i in run_args]
        LOG.info(f"Running command: {' '.join(run_args)}")
        start = time.time()

        child_env = dict(os.environ if env is None else env)
        child_env["PYTHONUNBUFFERED"] = "1"

        process = subprocess.Popen(
            run_args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            env=child_env,
            # Start in a new process group so we can kill the entire tree
            # (nnUNet spawns export worker subprocesses) on timeout.
            start_new_session=True,
        )

        last_output_time = time.time()
        timeout_logged = False

        while True:
            # Use select with a 1-second timeout so we can check inactivity
            # even when the process produces no output.
            ready, _, _ = select.select([process.stdout], [], [], 1.0)

            if ready:
                line = process.stdout.readline()
                if not line:
                    # EOF — stdout pipe closed
                    break
                last_output_time = time.time()
                timeout_logged = False
                LOG.info(f"[nnUNet] {line.rstrip()}")

            # Check inactivity timeout
            idle_secs = time.time() - last_output_time
            if idle_secs > SUBPROCESS_INACTIVITY_TIMEOUT:
                if not timeout_logged:
                    LOG.error(
                        f"nnUNet subprocess hung (no stdout for {idle_secs:.0f}s, "
                        f"timeout={SUBPROCESS_INACTIVITY_TIMEOUT}s), killing PID {process.pid}"
                    )
                    timeout_logged = True
                # Kill the entire process group so child workers also die
                try:
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    process.kill()
                process.wait()
                elapsed = time.time() - start
                LOG.error(
                    f"nnUNet subprocess killed after {elapsed:.1f}s due to inactivity timeout: {' '.join(run_args)}"
                )
                raise subprocess.TimeoutExpired(
                    cmd=run_args,
                    timeout=SUBPROCESS_INACTIVITY_TIMEOUT,
                )

            # Check if process exited (even if no output was produced)
            if process.poll() is not None:
                # Drain any remaining output
                for line in process.stdout:
                    LOG.info(f"[nnUNet] {line.rstrip()}")
                break

        process.wait()
        elapsed = time.time() - start
        LOG.info(f"Command finished in {elapsed:.1f}s with return code {process.returncode}: {' '.join(run_args)}")

        if process.returncode != 0:
            # Signal-aware diagnostics (P1-12): negative return codes indicate
            # the process was killed by a signal (e.g. SIGKILL from OOM killer)
            if process.returncode < 0:
                try:
                    sig_name = signal.Signals(-process.returncode).name
                except ValueError:
                    sig_name = f"signal {-process.returncode}"
                LOG.error(
                    f"nnUNet command killed by {sig_name} (exit code {process.returncode}). "
                    f"This often indicates an OOM kill by the OS/cgroup OOM killer."
                )
            else:
                LOG.error(f"nnUNet command failed with exit code {process.returncode}")
            raise subprocess.CalledProcessError(
                process.returncode,
                run_args,
            )


default_nnunet_adapter = NNUNetV2Adapter(
    "data/nnUNet_raw",
    "data/nnUNet_preprocessed",
    "data/nnUNet_results",
)
