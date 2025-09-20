# Use official NVIDIA CUDA runtime with Ubuntu 22.04 and cuDNN
FROM nvcr.io/nvidia/cuda:13.0.1-cudnn-devel-ubuntu22.04

# Arguments for user/group IDs
ARG UID=1000
ARG GID=1000

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    CONDA_DIR=/home/draw/miniconda3 \
    APP_USER=draw \
    APP_HOME=/home/draw \
    EFS_MOUNT=/mnt/efs

# Install system dependencies and clean up in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    git \
    build-essential \
    ca-certificates \
    inotify-tools \
    unzip \
    screen \
    sqlite3 \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user and set up environment with specific UID first
RUN groupadd -r -g $GID $APP_USER 2>/dev/null || groupadd -r $APP_USER && \
    useradd -m -r -u $UID -g $GID -d $APP_HOME -s /bin/bash $APP_USER && \
    mkdir -p $APP_HOME && \
    chown -R $APP_USER:$APP_USER $APP_HOME

# Switch to non-root user for the rest of the build
USER $APP_USER
WORKDIR $APP_HOME

# Create required directories with proper permissions
RUN mkdir -p \
    $APP_HOME/pipeline/data/nnUNet_results \
    $APP_HOME/pipeline/output \
    $APP_HOME/pipeline/logs \
    $APP_HOME/pipeline/dicom \
    $APP_HOME/copy_dicom \
    $APP_HOME/pipeline/bin && \
    find $APP_HOME -type d -exec chmod 755 {} \;

# Copy application files
COPY --chown=$APP_USER:$APP_USER . $APP_HOME/pipeline/    

# Install and configure miniconda with environment setup
RUN set -e && \
    # Download and install miniconda
    wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh && \
    bash /tmp/miniconda.sh -b -p $CONDA_DIR && \
    rm /tmp/miniconda.sh && \
    # Configure conda
    $CONDA_DIR/bin/conda config --system --set auto_activate_base false && \
    $CONDA_DIR/bin/conda config --system --add channels conda-forge && \
    $CONDA_DIR/bin/conda config --system --set channel_priority strict && \
    # Accept conda terms of service
    $CONDA_DIR/bin/conda tos accept --override-channels \
        --channel https://repo.anaconda.com/pkgs/main \
        --channel https://repo.anaconda.com/pkgs/r && \
    # Set up environment
    echo "export PATH=\$CONDA_DIR/bin:\$PATH" >> ~/.bashrc && \
    echo "eval \"\$($CONDA_DIR/bin/conda shell.bash hook)\"" >> ~/.bashrc && \
    . $CONDA_DIR/etc/profile.d/conda.sh && \
    # Create environment and install packages
    $CONDA_DIR/bin/conda env create -f $APP_HOME/pipeline/environment.yml -n draw && \
    # Clean up
    $CONDA_DIR/bin/conda clean --all -y && \
    find $CONDA_DIR -type f -name '*.py[co]' -delete && \
    find $CONDA_DIR -type f -name '*.js.map' -delete && \
    rm -rf $CONDA_DIR/pkgs/*

# Set environment variables for the container
ENV PATH=$CONDA_DIR/envs/draw/bin:$PATH \
    CONDA_DEFAULT_ENV=draw \
    CONDA_PREFIX=$CONDA_DIR/envs/draw \
    PYTHONUNBUFFERED=1

# Switch to root to handle entrypoint script
USER root

# Copy entrypoint script and set proper permissions
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh && \
    chown $APP_USER:$APP_USER /entrypoint.sh

# Switch back to non-root user for runtime
USER $APP_USER

# Set the entrypoint and default command
ENTRYPOINT ["/entrypoint.sh"]

