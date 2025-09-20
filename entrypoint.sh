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
# The pipeline folder is located at /home/draw/pipeline
# First activate the conda environment called draw
cd /home/draw/pipeline
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

# Create database using alembic

alembic upgrade head


# Check if the database is created successfully. The database is created as a sqlite database called draw.db.sqlite in the data directory.
if [ ! -f /home/draw/pipeline/data/draw.db.sqlite ]; then
    log "Error: Database is not created successfully"
    exit 1
else
    log "Database is created successfully"
fi

# Delete the output directory if it exists and recreate it
log "Preparing output directory..."
rm -rf /home/draw/pipeline/output
mkdir -p /home/draw/pipeline/output

# Create parent directory if it doesn't exist
mkdir -p /home/draw/pipeline/data

# Create the symlink
log "Creating nnUNet results symlink..."

# Ensure target directory exists
mkdir -p /home/draw/pipeline/data

# Remove any existing symlink or directory
if [ -e "/home/draw/pipeline/data/nnUNet_results" ]; then
    rm -rf "/home/draw/pipeline/data/nnUNet_results"
fi

# Create the symlink
ln -sf /mnt/efs/nnUNet_results /home/draw/pipeline/data/nnUNet_results

# Verify and log EFS mount directory contents
if [ -d "/mnt/efs/nnUNet_results" ]; then
    log "Listing contents of EFS mount directory (/mnt/efs/nnUNet_results):"
    if ! ls -RS /mnt/efs/nnUNet_results 2>/dev/null; then
        log "Warning: Failed to list EFS contents"
    fi
else
    log "Error: EFS directory /mnt/efs/nnUNet_results does not exist"
    exit 1
fi

# Check EFS filesystem type and permissions
df -Th /mnt/efs
ls -ld /mnt/efs /home/draw/pipeline/data
mount | grep efs

# Verify and log symlink directory contents
if [ -L "/home/draw/pipeline/data/nnUNet_results" ]; then
    log "Listing contents of symlink directory (/home/draw/pipeline/data/nnUNet_results):"
    if ! ls -RS /home/draw/pipeline/data/nnUNet_results 2>/dev/null; then
        log "Error: Failed to list symlink contents - check permissions or target"
        exit 1
    fi
else
    log "Error: Symlink /home/draw/pipeline/data/nnUNet_results does not exist or is not a symlink"
    exit 1
fi

#
# Create necessary directories
log "Creating necessary directories..."
mkdir -p /home/draw/pipeline/logs
mkdir -p /home/draw/copy_dicom/files

# Start the pipeline in a detached screen session
log "Starting the pipeline in a detached screen session..."
source ~/miniconda3/etc/profile.d/conda.sh
conda activate draw
screen -d -m python main.py start-pipeline

# Wait for pipeline to start
log "Waiting for pipeline to initialize..."
sleep 10


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
if ! find /home/draw/copy_dicom/files -type f -name "*.dcm" -exec mv {} /home/draw/pipeline/dicom/ \;; then
    log "Error: Failed to move DICOM files"
    exit 1
fi


# Check if the logfile has been created at the logs directory
# Retry for 5 minutes at 1 minute intervals before giving up and raising an error
log "Waiting for pipeline log file to be created..."
log_found=false
for i in {1..5}; do
    if [ -f /home/draw/pipeline/logs/logfile.log ]; then
        log "Log file found"
        cat /home/draw/pipeline/logs/logfile.log
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

# Check the newly created database using alembic. 
# This database is created in the previous step
# We need to query the database to check if the series instance uid is now at the INIT status 
# If not repeat the check for at least 5 minutes at 30 sec interval before exiting. 
# The database definition is available at alembic\versions\de871710e5d0_db_config.py. The column name to search for is series_name
# The series instance UID value will match the series instance UID available in the environment variables. seriesInstanceUID

log "Checking database for series instance UID: ${seriesInstanceUID}"
db_check_found=false
max_attempts=10  # 5 minutes / 30 seconds = 10 attempts

for attempt in $(seq 1 $max_attempts); do
    log "Database check attempt $attempt/$max_attempts..."
    
    # Query the database using sqlite3 to check if series_name exists with INIT status
    db_result=$(sqlite3 /home/draw/pipeline/data/draw.db.sqlite \
        "SELECT COUNT(*) FROM dicomlog WHERE series_name = '${seriesInstanceUID}' AND status = 'INIT';" 2>/dev/null || echo "0")
    
    if [ "$db_result" -gt 0 ]; then
        log "Found series instance UID '${seriesInstanceUID}' with INIT status in database"
        db_check_found=true
        break
    else
        # Check if the series exists with any status
        series_exists=$(sqlite3 /home/draw/pipeline/data/draw.db.sqlite \
            "SELECT COUNT(*) FROM dicomlog WHERE series_name = '${seriesInstanceUID}';" 2>/dev/null || echo "0")
        
        if [ "$series_exists" -gt 0 ]; then
            # Get the current status
            current_status=$(sqlite3 /home/draw/pipeline/data/draw.db.sqlite \
                "SELECT status FROM dicomlog WHERE series_name = '${seriesInstanceUID}' LIMIT 1;" 2>/dev/null || echo "UNKNOWN")
            log "Series instance UID '${seriesInstanceUID}' found with status: $current_status"
        else
            log "Series instance UID '${seriesInstanceUID}' not found in database yet"
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log "Waiting 30 seconds before next attempt..."
            sleep 30
        fi
    fi
done

if [ "$db_check_found" = false ]; then
    log "Error: Series instance UID '${seriesInstanceUID}' with INIT status not found in database after 5 minutes"
    log "Checking database contents for debugging:"
    sqlite3 /home/draw/pipeline/data/draw.db.sqlite \
        "SELECT series_name, status, created_on FROM dicomlog ORDER BY created_on DESC LIMIT 10;" 2>/dev/null || log "Failed to query database"
    exit 1
fi

log "Database check completed successfully - series ready for processing"



# Wait for the automatic segmentation to complete by checking for AUTOSEGMENT.RT.dcm
log "Waiting for auto-segmentation to complete..."
if command -v inotifywait &> /dev/null; then
    log "Using inotifywait to monitor for file creation..."
    if timeout 1200 inotifywait -e create --format '%f' -q /home/draw/pipeline/output/ | grep -q "AUTOSEGMENT.RT.dcm"; then
        log "Auto-segmentation file found"
    else
        # Check if file exists in case it was created before inotify started watching
        if [ -f "/home/draw/pipeline/output/AUTOSEGMENT.RT.dcm" ]; then
            log "Auto-segmentation file found"
        else
            log "Error: Auto-segmentation file not found after 20 minutes of waiting"
            log "Contents of the log file:"
            cat /home/draw/pipeline/logs/logfile.log
            exit 1
        fi
    fi
else
    log "inotify-tools not available, falling back to polling..."
    auto_segment_file_found=false
    for i in {1..40}; do
        if [ -f /home/draw/pipeline/output/AUTOSEGMENT.RT.dcm ]; then
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
        cat /home/draw/pipeline/logs/logfile.log
        exit 1
    fi
fi

# Wait briefly before final copy to ensure all writes are complete
log "Waiting for 15 seconds for final writes to complete..."
sleep 15

# Define output file paths
local_output_file="/home/draw/pipeline/output/AUTOSEGMENT.RT.dcm"
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
if [ -f /home/draw/pipeline/logs/pipeline.log ]; then
    cat /home/draw/pipeline/logs/pipeline.log
fi

# Exit with success
exit 0