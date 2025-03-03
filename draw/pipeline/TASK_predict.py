from itertools import cycle
import time
from typing import List

from draw.config import (
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
        time.sleep(PREDICTION_COOLDOWN_SECS)
        run_prediction_with_retry(seg_model_name, all_dcm_files, data_path)
        pred_dcm_logs = DBConnection.top(seg_model_name, Status.PREDICTED)
        LOG.info(f"Got {len(pred_dcm_logs)} from DB")
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


import sqlite3
import os

def query():
    # This function returns records whose status = 'INIT'
    file_path = os.path.abspath(__file__) # /home/koustav/Work/Pipeline/draw-seg-v3_021224/draw/pipeline/TASK_predict.py
    parts = file_path.split(os.sep)
    base_path = os.sep.join(parts[:parts.index('draw')]) # /home/koustav/Work/Pipeline/draw-seg-v3_021224/
    db_directory = base_path + '/data' # /home/koustav/Work/Pipeline/draw-seg-v3_021224/data

    # db_directory = "/home/koustav/Work/Pipeline/draw-seg-v3_021224/data"
    db_name = "draw.db.sqlite"
    db_path = os.path.join(db_directory, db_name)

    try:
        connection = sqlite3.connect(db_path)
        #print(f"Connected to the database at {db_path}")

        cursor = connection.cursor()
        sql_query = "SELECT model,input_path FROM dicomlog where status = 'INIT' "
        cursor.execute(sql_query)
        records = cursor.fetchall()

        for record in records:
            print(record)

    except sqlite3.Error as e:
        print(f"Error connecting to database: {e}")

    finally:
        if connection:
            connection.close()
            #print("Database connection closed.")
        return records
    
    


def initiate_model_prediction(model_name, data_path):
    # for model_name in draw.config.MODEL_CONFIG["KEYS"]:
    try:
        gpu_memory_free = get_gpu_memory()
        any_model_ran = False
        print("gpu_memory_free:", gpu_memory_free)
        print("REQUIRED_FREE_MEMORY_BYTES:", REQUIRED_FREE_MEMORY_BYTES)

        if gpu_memory_free >= REQUIRED_FREE_MEMORY_BYTES:
            LOG.info(f"{gpu_memory_free} MB free GPU. Trying {model_name}")
            LOG.info(f" 'initiate_model_predict' called with model_name = {model_name} and data_path = {data_path}")
            print("model name:",model_name, " data_path:", data_path)
            print(run_prediction(model_name, data_path))
            any_model_ran = any_model_ran or run_prediction(model_name, data_path)

        if not any_model_ran:
            LOG.info(f"{model_name} ran: {any_model_ran}")
            time.sleep(GPU_RECHECK_TIME_SECONDS)
    except Exception:
        LOG.error("Exception Ignored", exc_info=True)


def task_model_prediction():
    # Python 3.8 minimum for this operator
    interval = 10 #in seconds
    while True:
        #print("function call starts")
        result = query()
        if len(result) > 0:
            if result[0][0] and result[0][1]:
                initiate_model_prediction(str(result[0][0]), str(result[0][1]))
            else:
                LOG.info("Either of Model or input_path is empty and not valid")
        else:
            LOG.info('No remaining task found form DB')
        time.sleep(interval)