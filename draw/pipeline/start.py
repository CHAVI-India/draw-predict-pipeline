from multiprocessing import Process

from draw.config import LOG
from draw.pipeline.TASK_copy import task_watch_dir
from draw.pipeline.TASK_predict import task_model_prediction


def start_continuous_prediction():
    all_processes = []
    process_functions = [task_model_prediction, task_watch_dir]
    for fxn in process_functions:
        p = Process(target=fxn)
        LOG.info(f"Starting process: {fxn.__name__} (PID will be assigned on start)")
        p.start()
        LOG.info(f"Process {fxn.__name__} started with PID: {p.pid}")
        all_processes.append((fxn.__name__, p))
    for name, p in all_processes:
        p.join()
        LOG.info(f"Process {name} (PID={p.pid}) exited with code {p.exitcode}")
