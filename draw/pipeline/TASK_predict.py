from itertools import cycle
import time
from typing import List
import sqlite3
import os
from draw.config import DB_CONFIG

from draw.config import (
    DB_CONFIG,
    MODEL_CONFIG,
    LOG,
    OUTPUT_DIR,
    PREDICTION_COOLDOWN_SECS,
    GPU_RECHECK_TIME_SECONDS,
    REQUIRED_FREE_MEMORY_BYTES,
)
from draw.dao.common import Status
from draw.dao.db import DBConnection
from draw.dao.table import DicomLog
from draw.predict import folder_predict
from retry.api import retry_call

from draw.utils.ioutils import get_gpu_memory


def send_to_external_server(pred_dcm_logs: List[DicomLog]):
    # dcm_output_dirs = [dcm.output_path for dcm in pred_dcm_logs]
    # TODO: dcm_output_dirs got, check how to send to server
    for dcm in pred_dcm_logs:
        DBConnection.update_status_by_id(dcm, Status.SENT)
    LOG.info(f"Sent {len(pred_dcm_logs)} to server")


def run_prediction(seg_model_name, data_path):
    all_dcm_files = DBConnection.dequeue(seg_model_name)
    if len(all_dcm_files) > 0:
        LOG.info(f"[run_prediction] Dequeued {len(all_dcm_files)} file(s) for model '{seg_model_name}', waiting {PREDICTION_COOLDOWN_SECS}s cooldown...")
        time.sleep(PREDICTION_COOLDOWN_SECS)
        LOG.info(f"[run_prediction] Starting prediction for model '{seg_model_name}'")
        pred_start = time.time()
        run_prediction_with_retry(seg_model_name, all_dcm_files, data_path)
        LOG.info(f"[run_prediction] Prediction for model '{seg_model_name}' finished in {time.time() - pred_start:.1f}s")
        pred_dcm_logs = DBConnection.top(seg_model_name, Status.PREDICTED)
        LOG.info(f"[run_prediction] Got {len(pred_dcm_logs)} PREDICTED record(s) from DB")
        send_to_external_server(pred_dcm_logs)
        return True
    return False


def run_prediction_with_retry(seg_model_name, all_dcm_files, data_path):
    retry_call(
        folder_predict,
        fargs=(
            all_dcm_files,
            OUTPUT_DIR,
            seg_model_name,
            data_path,
            True,
        ),
        tries=2,
        logger=LOG,
        delay=PREDICTION_COOLDOWN_SECS,
    )


# #Below is the implementation when we have fixed set of .yml in 'config.yml' folder
# def task_model_prediction():
#     # Python 3.8 minimum for this operator
#     model_name_generator = cycle(MODEL_CONFIG["KEYS"])
#     while model_name := next(model_name_generator):
#         try:
#             gpu_memory_free = get_gpu_memory()
#             any_model_ran = False

#             if gpu_memory_free >= REQUIRED_FREE_MEMORY_BYTES:
#                 LOG.info(f"{gpu_memory_free} MB free GPU. Trying {model_name}")
#                 any_model_ran = any_model_ran or run_prediction(model_name)

#             if not any_model_ran:
#                 LOG.info(f"{model_name} ran: {any_model_ran}")
#                 time.sleep(GPU_RECHECK_TIME_SECONDS)
#         except Exception:
#             LOG.error("Exception Ignored", exc_info=True)
#             continue


def query():
    # This function returns records whose status = 'INIT'
    # Extract the database path from the DB_URL configuration
    db_url = DB_CONFIG["URL"]
    # Remove the sqlite:/// prefix to get the actual file path
    db_path = db_url.replace("sqlite:///", "")

    try:
        connection = sqlite3.connect(db_path)
        cursor = connection.cursor()
        sql_query = "SELECT model,input_path FROM dicomlog where status = 'INIT' "
        cursor.execute(sql_query)
        records = cursor.fetchall()
        LOG.info(f"[query] Found {len(records)} INIT record(s) in DB")
        for record in records:
            LOG.info(f"[query] Record: model={record[0]}, input_path={record[1]}")

    except sqlite3.Error as e:
        LOG.error(f"[query] Error connecting to database: {e}")
        records = []

    finally:
        if connection:
            connection.close()
        return records
    
    


def initiate_model_prediction(model_name, data_path):
    try:
        gpu_memory_free = get_gpu_memory()
        any_model_ran = False
        LOG.info(f"[initiate_model_prediction] gpu_memory_free={gpu_memory_free} MB, required={REQUIRED_FREE_MEMORY_BYTES} MB")

        if gpu_memory_free >= REQUIRED_FREE_MEMORY_BYTES:
            LOG.info(f"[initiate_model_prediction] Sufficient GPU memory. Starting model='{model_name}', data_path='{data_path}'")
            start = time.time()
            any_model_ran = any_model_ran or run_prediction(model_name, data_path)
            LOG.info(f"[initiate_model_prediction] run_prediction returned {any_model_ran} in {time.time() - start:.1f}s")
        else:
            LOG.info(f"[initiate_model_prediction] Insufficient GPU memory ({gpu_memory_free} MB < {REQUIRED_FREE_MEMORY_BYTES} MB), skipping")

        if not any_model_ran:
            LOG.info(f"[initiate_model_prediction] No prediction ran for model='{model_name}', sleeping {GPU_RECHECK_TIME_SECONDS}s")
            time.sleep(GPU_RECHECK_TIME_SECONDS)
    except Exception:
        LOG.error("[initiate_model_prediction] Exception caught", exc_info=True)


def task_model_prediction():
    # Python 3.8 minimum for this operator
    interval = 10  # in seconds
    while True:
        result = query()
        if len(result) > 0:
            model_name = result[0][0]
            input_path = result[0][1]
            if model_name and input_path:
                LOG.info(f"[task_model_prediction] Dispatching: model='{model_name}', input_path='{input_path}'")
                initiate_model_prediction(str(model_name), str(input_path))
            else:
                LOG.info(f"[task_model_prediction] Record has empty model or input_path: {result[0]}")
        else:
            LOG.info("[task_model_prediction] No remaining tasks found in DB")
        time.sleep(interval)