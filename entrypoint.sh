#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Logging function only on console. So tee is not needed.
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" 
}

# Function to clean up on exit
cleanup() {
    local exit_code=$?
    log "Starting cleanup..."
    
    # Kill any background processes
    pkill -P $$ || true
    
    log "Cleanup complete. Exiting with code $exit_code"
    exit $exit_code
}

# Set up trap to call cleanup on script exit
trap cleanup EXIT


# Check if required environment variables are set
required_vars=(
    "inputS3Path"
    "outputS3Path"
    "seriesInstanceUID"
    "studyInstanceUID"
    "patientID"
    "transactionToken"
    "fileUploadId"
)

missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -ne 0 ]; then
    log "Error: The following required environment variables are not set:"
    for var in "${missing_vars[@]}"; do
        log "  - $var"
    done
    exit 1
fi

log "Job parameters:"
log "  Input S3 Path: ${inputS3Path}"
log "  Output S3 Path: ${outputS3Path}"
log "  Series Instance UID: ${seriesInstanceUID}"
log "  Study Instance UID: ${studyInstanceUID}"
log "  Patient ID: ${patientID}"
log "  Transaction Token: ${transactionToken:0:4}...${transactionToken: -4}"  # Show partial token for security
log "  File Upload ID: ${fileUploadId}"

# Main execution starts here
log "=== nnUNet Autosegmentation Job Started ==="

# Log all arguments for debugging
log "Script arguments: $*"

# Start the DRAW pipeline in a detached screen session so that it can be monitored. 
# The pipeline folder is located at /home/draw/draw
# First activate the conda environment called draw
cd /home/draw/draw
log "Changed directory to home directory"

source ~/miniconda3/etc/profile.d/conda.sh && conda activate draw
log "Activated conda environment"

# Next we need to create the database using alembic
# First check if alembic is available in the conda environment
if [ -z "$(which alembic)" ]; then
    log "Error: alembic is not available in the conda environment"
    exit 1
else
    log "alembic is available in the conda environment"
fi 

# Load environment configuration
ALEMBIC_SCRIPT_LOCATION=$(grep 'ALEMBIC_SCRIPT_LOCATION:' /home/draw/env.draw.yml | cut -d ' ' -f2)
if [ -z "$ALEMBIC_SCRIPT_LOCATION" ]; then
    log "Error: ALEMBIC_SCRIPT_LOCATION not found in env.draw.yml"
    exit 1
fi

# Create a temporary alembic.ini with the correct script_location
TEMP_ALEMBIC_INI="/tmp/alembic.ini.$$"
cp /home/draw/draw/alembic.ini "$TEMP_ALEMBIC_INI"
sed -i "s|script_location = .*|script_location = $ALEMBIC_SCRIPT_LOCATION|" "$TEMP_ALEMBIC_INI"

# Create the alembic database
log "Creating database with alembic..."
ALEMBIC_CONFIG="$TEMP_ALEMBIC_INI" alembic -c "$TEMP_ALEMBIC_INI" upgrade head



# Check if the database is created successfully. The database is created as a sqlite database called draw.db.sqlite in the data directory.
if [ ! -f /home/draw/draw/data/draw.db.sqlite ]; then
    log "Error: Database is not created successfully"
    exit 1
else
    log "Database is created successfully"
fi

# Delete the output directory if it exists and recreate it
log "Preparing output directory..."
rm -rf /home/draw/draw/output
mkdir -p /home/draw/draw/output

# Symlink the efs mount to the output directory
log "Setting up nnUNet results symlink..."
ln -sf /mnt/efs/nnUNet_results /home/draw/draw/data/nnUNet_results

# Check if we can see models in the nnUNet directory
if [ $(ls -1 /home/draw/draw/data/nnUNet_results | wc -l) -eq 0 ]; then
    log "Error: No models found in the nnUNet_results directory"
    exit 1
else
    log "Found $(ls -1 /home/draw/draw/data/nnUNet_results | wc -l) models in nnUNet_results directory"
fi

# Create necessary directories
log "Creating necessary directories..."
mkdir -p /home/draw/draw/logs
mkdir -p /home/draw/copy_dicom/files

# Start the pipeline in the background
log "Starting the pipeline..."
{
    source ~/miniconda3/etc/profile.d/conda.sh
    conda activate draw
    python main.py start-pipeline
} > "/home/draw/draw/logs/pipeline.log" 2>&1 &
PIPELINE_PID=$!

# Function to check if pipeline is running
check_pipeline_running() {
    if ! kill -0 $PIPELINE_PID 2>/dev/null; then
        log "Error: Pipeline process is not running"
        log "Pipeline logs:"
        cat "/home/draw/draw/logs/pipeline.log"
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
for dir in "/home/draw/copy_dicom" "/home/draw/draw/dicom" "/home/draw/draw/output" "/home/draw/draw/logs"; do
    if [ ! -d "$dir" ]; then
        log "Error: Directory $dir does not exist"
        exit 1
    fi
done

# Download DICOM zip from S3
local_zip_path="/home/draw/copy_dicom/file_upload_${fileUploadId}_dicom.zip"
log "Downloading DICOM zip from ${inputS3Path}..."
if ! aws s3 cp "${inputS3Path}" "${local_zip_path}"; then
    log "Error: Failed to download DICOM zip from S3"
    exit 1
fi

# Verify zip file exists and is not empty
if [[ ! -s "${local_zip_path}" ]]; then
    log "Error: Downloaded DICOM zip is empty or not found"
    exit 1
fi

# Extract the zip file
log "Extracting DICOM zip..."
if ! unzip -q "${local_zip_path}" -d "/home/draw/copy_dicom/files/"; then
    log "Error: Failed to extract DICOM zip"
    exit 1
fi

# Move DICOM files to watch directory
log "Moving DICOM files to watch directory..."
if ! find /home/draw/copy_dicom/files -type f -name "*.dcm" -exec mv {} /home/draw/draw/dicom/ \;; then
    log "Error: Failed to move DICOM files"
    exit 1
fi

# Wait for 60 seconds for pipeline to detect files
log "Waiting for pipeline to detect DICOM files..."
sleep 60

# Check if the logfile has been created at the logs directory
# Retry for 5 minutes at 1 minute intervals before giving up and raising an error
log "Waiting for pipeline log file to be created..."
log_found=false
for i in {1..5}; do
    if [ -f /home/draw/draw/logs/logfile.log ]; then
        log "Log file found"
        log_found=true
        break
    fi
    sleep 60
    log "Log file not found, retrying... ($i/5)"
done    
if [ "$log_found" = false ]; then
    log "Error: Log file not found after 5 minutes of waiting"
    exit 1
fi

# If the logfile is found check if the DICOM data has been recognized
# We will check if the log file contains reference to the dicom directory
log "Checking if DICOM data has been recognized by pipeline..."
dicom_recognized=false
for i in {1..10}; do
    if grep -q "dicom" /home/draw/draw/logs/logfile.log; then
        log "DICOM data recognized"
        dicom_recognized=true
        break
    fi
    sleep 30
    log "DICOM data not recognized, retrying... ($i/10)"
done    
if [ "$dicom_recognized" = false ]; then
    log "Error: DICOM data not recognized in the pipeline after 5 minutes of waiting"
    log "Contents of the log file:"
    cat /home/draw/draw/logs/logfile.log
    exit 1
fi

# Wait for the automatic segmentation to complete by checking for AUTOSEGMENT.RT.dcm
log "Waiting for auto-segmentation to complete..."
if command -v inotifywait &> /dev/null; then
    log "Using inotifywait to monitor for file creation..."
    if timeout 1200 inotifywait -e create --format '%f' -q /home/draw/draw/output/ | grep -q "AUTOSEGMENT.RT.dcm"; then
        log "Auto-segmentation file found"
    else
        # Check if file exists in case it was created before inotify started watching
        if [ -f "/home/draw/draw/output/AUTOSEGMENT.RT.dcm" ]; then
            log "Auto-segmentation file found"
        else
            log "Error: Auto-segmentation file not found after 20 minutes of waiting"
            log "Contents of the log file:"
            cat /home/draw/draw/logs/logfile.log
            exit 1
        fi
    fi
else
    log "inotify-tools not available, falling back to polling..."
    auto_segment_file_found=false
    for i in {1..40}; do
        if [ -f /home/draw/draw/output/AUTOSEGMENT.RT.dcm ]; then
            log "Auto-segmentation file found"
            auto_segment_file_found=true
            break
        fi
        sleep 30
        log "Auto-segmentation file not found, retrying... ($i/40)"
    done    
    if [ "$auto_segment_file_found" = false ]; then
        log "Error: Auto-segmentation file not found after 20 minutes of waiting"
        log "Contents of the logfile:"
        cat /home/draw/draw/logs/logfile.log
        exit 1
    fi
fi

# Wait briefly before final copy to ensure all writes are complete
log "Waiting for 15 seconds for final writes to complete..."
sleep 15

# Define output file paths
local_output_file="/home/draw/draw/output/AUTOSEGMENT.RT.dcm"
s3_output_path="${outputS3Path}/AUTOSEGMENT.RT.${fileUploadId}.dcm"

# Verify output file exists and is not empty
if [[ ! -s "${local_output_file}" ]]; then
    log "Error: Output file is empty or not found at ${local_output_file}"
    exit 1
fi

log "Output file size: $(stat -c%s "${local_output_file}") bytes"

# Upload the result to S3
log "Uploading result to ${s3_output_path}..."
if ! aws s3 cp "${local_output_file}" "${s3_output_path}"; then
    log "Error: Failed to upload result to S3"
    exit 1
fi

# Verify the upload was successful
if ! aws s3 ls "${s3_output_path}" &>/dev/null; then
    log "Error: Failed to verify S3 upload"
    exit 1
fi

log "Auto-segmentation completed successfully"
log "Result available at: ${s3_output_path}"
log "Final pipeline log:"
if [ -f /home/draw/draw/logs/pipeline.log ]; then
    cat /home/draw/draw/logs/pipeline.log
fi

# Exit with success
exit 0