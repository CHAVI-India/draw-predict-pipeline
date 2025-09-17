#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Exit if not running as non-root user
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: This script should not be run as root" >&2
    exit 1
fi

# Function to clean up on exit
cleanup() {
    local exit_code=$?
    log "Starting cleanup..."
    
    # Kill any background processes
    pkill -P $$ || true
    
    # Clean up temporary files
    rm -rf "/home/draw/copy_dicom"/* "$TEMP_DIR"
    
    log "Cleanup complete. Exiting with code $exit_code"
    exit $exit_code
}

# Set up trap to call cleanup on script exit
trap cleanup EXIT

# Function to validate required environment variables
validate_env() {
    local required_vars=(
        "inputS3Path"
        "outputS3Path"
        "seriesInstanceUID"
        "studyInstanceUID"
        "patientID"
        "transactionToken"
        "fileUploadId"
    )
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "Error: Missing required environment variables: ${missing_vars[*]}" >&2
        exit 1
    fi

    # Sanitize fileUploadId to prevent command injection
    if [[ ! "${fileUploadId}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Invalid fileUploadId format" >&2
        exit 1
    fi
}

# Function to log messages with timestamp and log level
log() {
    local level="${1:-INFO}"
    local message="${2:-$1}"
    if [ "$level" = "$message" ]; then
        level="INFO"
    else
        shift
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level^^}] $message"
}

# Main execution starts here
log "=== nnUNet Autosegmentation Job Started ==="
log "Validating environment variables..."
validate_env

log "Job parameters:"
log "  Input S3 Path: ${inputS3Path}"
log "  Output S3 Path: ${outputS3Path}"
log "  Series Instance UID: ${seriesInstanceUID}"
log "  Study Instance UID: ${studyInstanceUID}"
log "  Patient ID: ${patientID}"
log "  Transaction Token: ${transactionToken:0:4}...${transactionToken: -4}"  # Show partial token for security
log "  File Upload ID: ${fileUploadId}"

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


# Start the pipeline in the background
log "Starting the pipeline..."
{
    source "$CONDA_PREFIX/etc/profile.d/conda.sh"
    conda activate draw
    python main.py start-pipeline
} > "/home/draw/logs/pipeline.log" 2>&1 &
PIPELINE_PID=$!

# Function to check if pipeline is running
check_pipeline_running() {
    if ! kill -0 $PIPELINE_PID 2>/dev/null; then
        log "Error: Pipeline process is not running"
        log "Pipeline logs:"
        cat "/home/draw/logs/pipeline.log"
        return 1
    fi
    return 0
}

# Wait for pipeline to start
log "Waiting for pipeline to initialize..."
sleep 5

if ! check_pipeline_running; then
    exit 1 # Logging happens in the function call.
fi

log "Pipeline started successfully (PID: $PIPELINE_PID)"

# Ensure directories exist with correct permissions
log "Verifying working directories..."
for dir in "/home/draw/copy_dicom" "/home/draw/dicom" "/home/draw/output" "/home/draw/logs"; do
    if [ ! -d "$dir" ]; then
        log "Error: Directory $dir does not exist" >&2
        exit 1
    fi
done

# Download DICOM zip from S3
local_zip_path="/home/draw/copy_dicom/file_upload_${fileUploadId}_dicom.zip"
log "Downloading DICOM zip from ${inputS3Path}..."
if ! aws s3 cp "${inputS3Path}" "${local_zip_path}"; then
    log "Error: Failed to download DICOM zip from S3" >&2
    exit 1
fi

# Verify zip file exists and is not empty
if [[ ! -s "${local_zip_path}" ]]; then
    log "Error: Downloaded DICOM zip is empty or not found" >&2
    exit 1
fi

# Extract the zip file
log "Extracting DICOM zip..."
if ! unzip -q "${local_zip_path}" -d "/home/draw/copy_dicom/files/"; then
    log "Error: Failed to extract DICOM zip" >&2
    exit 1
fi

# Move DICOM files to watch directory
log "Moving DICOM files to watch directory..."
if ! find /home/draw/copy_dicom/files -type f -exec mv {} /home/draw/dicom/ \;; then
    log "Error: Failed to move DICOM files" >&2
    exit 1
fi


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
    echo "Contents of the log file:"
    cat /home/draw/logs/logfile.log # Copy the contents of the log file.
    exit 1
fi

# If the folder move is detected the next step is to wait for the automatic segmentation to complete. 
# Currently the most robust way to do that is to check for the file called AUTOSEGMENT.RT.dcm in the output folder. 
# Again we run a loop for the next 20 min checking at 30 second intervals to see if the file is present. 
# If the file is not present after 20 minutes then raise an error and exit.

echo "Waiting for auto-segmentation file to be created..."
if command -v inotifywait &> /dev/null; then
    echo "Using inotifywait to monitor for file creation..."
    if timeout 1200 inotifywait -e create --format '%f' -q /home/draw/output/ | grep -q "AUTOSEGMENT.RT.dcm"; then
        echo "Auto-segmentation file found"
    else
        # Check if file exists in case it was created before inotify started watching
        if [ -f "/home/draw/output/AUTOSEGMENT.RT.dcm" ]; then
            echo "Auto-segmentation file found"
        else
            echo "Error: Auto-segmentation file not found after 20 minutes of waiting"
            echo "Contents of the log file:"
            cat /home/draw/logs/logfile.log # Copy the contents of the log file.
            exit 1
        fi
    fi
else
    echo "inotify-tools not available, falling back to polling..."
    auto_segment_file_found=false
    for i in {1..20}; do
        if [ -f /home/draw/output/AUTOSEGMENT.RT.dcm ]; then
            echo "Auto-segmentation file found"
            auto_segment_file_found=true
            break
        fi
        sleep 30
        echo "Auto-segmentation file not found, retrying... ($i/20)"
    done    
    if [ "$auto_segment_file_found" = false ]; then
        echo "Error: Auto-segmentation file not found after 20 minutes of waiting"
        echo "Contents of the logfile:"
        cat /home/draw/logs/logfile.log # Copy the contents of the log file.
        exit 1
    fi
fi

# Wait briefly before final copy to ensure all writes are complete
log "Waiting for 15 sec for final writes to complete..."
sleep 15

# Define output file paths
local_output_file="/home/draw/output/AUTOSEGMENT.RT.dcm"
s3_output_path="${outputS3Path}/AUTOSEGMENT.RT.${fileUploadId}.dcm"

# Verify output file exists and is not empty
if [[ ! -s "${local_output_file}" ]]; then
    log "Error: Output file is empty or not found" >&2
    exit 1
fi

# Upload the result to S3
log "Uploading result to ${s3_output_path}..."
if ! aws s3 cp "${local_output_file}" "${s3_output_path}"; then
    log "Error: Failed to upload result to S3" >&2
    exit 1
fi

# Verify the upload was successful
if ! aws s3 ls "${s3_output_path}" &>/dev/null; then
    log "Error: Failed to verify S3 upload" >&2
    exit 1
fi

log "Auto-segmentation completed successfully"
log "Result available at: ${s3_output_path}"
log "Pipeline log:"
cat /home/draw/logs/pipeline.log

# Exit with success
exit 0
