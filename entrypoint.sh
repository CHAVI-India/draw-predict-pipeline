#!/bin/bash
set -e

echo "=== nnUNet Autosegmentation Job Started ==="
echo "Job parameters:"
echo "  Input S3 Path: ${inputS3Path}"          # ← Gets real value
echo "  Output S3 Path: ${outputS3Path}"        # ← Gets real value
echo "  Series Instance UID: ${seriesInstanceUID}"
echo "  Study Instance UID: ${studyInstanceUID}"
echo "  Patient ID: ${patientID}"
echo "  Transaction Token: ${transactionToken}"
echo "  File Upload ID: ${fileUploadId}"

# Parse S3 URIs - works with real values
parse_s3_uri() {
    local s3_uri=$1
    local path=${s3_uri#s3://}
    local bucket=${path%%/*}
    local key=${path#*/}
    echo "$bucket $key"
}

read INPUT_BUCKET INPUT_KEY <<< $(parse_s3_uri "${inputS3Path}")
read OUTPUT_BUCKET OUTPUT_KEY <<< $(parse_s3_uri "${outputS3Path}")



# Start the DRAW pipeline in a detached screen session so that it can be monitored. 
# The pipeline folder is located at /home/draw/draw
# First activate the conda environment called draw
# Terminal command is source ~/miniconda3/etc/profile.d/conda.sh && conda activate draw

cd /home/draw/draw

source ~/miniconda3/etc/profile.d/conda.sh && conda activate draw

cd /home/draw/draw

# Next we need to create the database using alembic
# First check if alembic is available in the conda environment
# The terminal command is cd /home/draw/draw && which alembic
# If alembic is not available then the container should show an error
if [ -z "$(which alembic)" ]; then
    echo "alembic is not available in the conda environment"
    exit 1
else
    echo "alembic is available in the conda environment"
fi 

# Create the alembic database
# The create database command is alembic upgrade head
alembic upgrade head

# Check if the database is created successfully. The database is created as a mysqlite database called draw.db.sqlite in the data directory.
# If the database is not created successfully then the container should show an error. Else log a message showing the successful creation.

if [ ! -f /home/draw/data/draw.db.sqlite ]; then
    echo "Database is not created successfully"
    exit 1
else
    echo "Database is created successfully"
fi




# Create the output directory if it does not exist. If it exists skip creation.
# Delete the output directory if it exists and recreate it

rm -rf /home/draw/output
mkdir -p /home/draw/output

# Symlink the efs mount to the output directory

ln -s /mnt/efs/nnUNet_results /home/draw/data/nnUNet_results

# Check if we can see models in the nnUNet directory. These will be subdirectories inside the nnUNet_results directory. 
# If the number of subdirectories is 0 then raise and error and exit.

if [ $(ls -l /home/draw/data/nnUNet_results | grep -c ^d) -eq 0 ]; then
    echo "No models found in the nnUNet_results directory"
    exit 1
fi


# Start the pipeline in a detached screen session. 

screen -dmS python main.py start-pipeline

# Wait for 5 seconds before proceeding further
sleep 5

# Check if the pipeline is running. If not raise an error and exit
# The terminal command is screen -ls | grep pipeline_session
if ! screen -ls | grep -q "pipeline_session"; then
    echo "Error: Failed to start the pipeline in screen session"
    exit 1
fi

# If the pipeline is activated then log the message
if screen -ls | grep -q "pipeline_session"; then
    echo "Pipeline is running in screen session"
fi

# Make a copy directory to copy the data from the AWS S3 endpoiont

mkdir -p /home/draw/copy_dicom

aws s3 cp "${inputS3Path}" "/home/draw/copy_dicom/"  

# The received file will have the name in the format file_upload_{file_upload_id}_dicom.zip

# As this is a zip file we will need to extract the contents into a subfolder inside the copy_dicom directory


unzip "/home/draw/copy_dicom/file_upload_${fileUploadId}_dicom.zip" -d "/home/draw/copy_dicom/files/" 


# Move the contents of the files subdirectory to the watch directory

mv /home/draw/copy_dicom/files/* /home/draw/dicom/


# Wait for 60 seconds
sleep 60

# Check if the logfile has been created at the logs directory
# Retry for 5 minutes at 1 minute intervals before giving up and raising an error

log_found=false
for i in {1..5}; do
    if [ -f /home/draw/logs/logfile.log ]; then
        echo "Log file found"
        log_found=true
        break
    fi
    sleep 60
    echo "Log file not found, retrying... ($i/5)"
done    
if [ "$log_found" = false ]; then
    echo "Error: Log file not found after 5 minutes of waiting"
    exit 1
fi

# If the logfile is found check if the DICOM data has been recognized
# We will check if the log file contain the folder path from where the dicom data was copied
# Again this will be checked at 30 seconds interval for 5 minutes before giving up and raising an error 

dicom_recognized=false
for i in {1..5}; do
    if grep -q "${copy_dicom}" /home/draw/logs/logfile.log; then
        echo "DICOM data recognized"
        dicom_recognized=true
        break
    fi
    sleep 30
    echo "DICOM data not recognized, retrying... ($i/5)"
done    
if [ "$dicom_recognized" = false ]; then
    echo "Error: DICOM data not recognized in the pipeline after 5 minutes of waiting"
    exit 1
fi

# If the folder move is detected the next step is to wait for the automatic segmentation to complete. 
# Currently the most robust way to do that is to check for the file called AUTOSEGMENT.RT.dcm in the output folder. 
# Again we run a loop for the next 15 min checking at 30 second intervals to see if the file is present. 
# If the file is not present after 15 minutes then raise an error and exit.

echo "Waiting for auto-segmentation file to be created..."
if command -v inotifywait &> /dev/null; then
    echo "Using inotifywait to monitor for file creation..."
    if timeout 900 inotifywait -e create --format '%f' -q /home/draw/output/ | grep -q "AUTOSEGMENT.RT.dcm"; then
        echo "Auto-segmentation file found"
    else
        # Check if file exists in case it was created before inotify started watching
        if [ -f "/home/draw/output/AUTOSEGMENT.RT.dcm" ]; then
            echo "Auto-segmentation file found"
        else
            echo "Error: Auto-segmentation file not found after 15 minutes of waiting"
            exit 1
        fi
    fi
else
    echo "inotify-tools not available, falling back to polling..."
    auto_segment_file_found=false
    for i in {1..15}; do
        if [ -f /home/draw/output/AUTOSEGMENT.RT.dcm ]; then
            echo "Auto-segmentation file found"
            auto_segment_file_found=true
            break
        fi
        sleep 30
        echo "Auto-segmentation file not found, retrying... ($i/15)"
    done    
    if [ "$auto_segment_file_found" = false ]; then
        echo "Error: Auto-segmentation file not found after 15 minutes of waiting"
        exit 1
    fi
fi

# Wait for 15 seconds before we copy the file back to the S3 output path and then exit

sleep 15

# Copy the file back to the S3 output path with a new name appending the file upload id to the file name
aws s3 cp "/home/draw/output/AUTOSEGMENT.RT.dcm" "${outputS3Path}/AUTOSEGMENT.RT.${fileUploadId}.dcm" 

# Log the successful retrieval

echo "Auto-segmentation file copied successfully to S3 output path"

# Terminate the container after the file has been copied successfully
exit 0
