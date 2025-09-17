# Use official NVIDIA CUDA runtime with Ubuntu 20.04 and cuDNN 8
FROM nvcr.io/nvidia/cuda:13.0.1-cudnn-devel-ubuntu24.04

# Arguments for user/group IDs
ARG UID=1000
ARG GID=1000

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    CONDA_DIR=/home/draw/miniconda3 \
    APP_USER=draw \
    APP_HOME=/draw \
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
    && rm -rf /var/lib/apt/lists/*

# Create the conda directory with proper permissions first
RUN mkdir -p $(dirname $CONDA_DIR) && \
    chmod 777 $(dirname $CONDA_DIR)

# Create non-root user and set up environment with specific UID
RUN groupadd -r -g $GID $APP_USER 2>/dev/null || groupadd -r $APP_USER && \
    useradd -m -r -u $UID -g $APP_USER -d $APP_HOME -s /bin/bash $APP_USER 2>/dev/null || \
    useradd -m -r -g $APP_USER -d $APP_HOME -s /bin/bash $APP_USER

# Create required directories with proper permissions
RUN mkdir -p \
    $APP_HOME/draw/data/nnUNet_results \
    $APP_HOME/draw/output \
    $APP_HOME/draw/logs \
    $APP_HOME/draw/dicom \
    $APP_HOME/copy_dicom \
    $APP_HOME/draw/bin \
    $EFS_MOUNT && \
    chown -R $APP_USER:$APP_USER $APP_HOME $EFS_MOUNT && \
    find $APP_HOME -type d -exec chmod 755 {} \; && \
    chmod 755 $EFS_MOUNT

# Switch to non-root user for Miniconda installation
USER $APP_USER
WORKDIR $APP_HOME

# Install Miniconda as the non-root user in a temporary location
RUN mkdir -p /tmp/conda_install && \
    cd /tmp/conda_install && \
    wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh && \
    bash miniconda.sh -b -p $CONDA_DIR && \
    rm -rf /tmp/conda_install && \
    # Initialize conda
    $CONDA_DIR/bin/conda init bash && \
    # Add conda to PATH
    echo "export PATH=$CONDA_DIR/bin:\$PATH" >> ~/.bashrc && \
    # Initialize conda in the current shell
    . $CONDA_DIR/etc/profile.d/conda.sh && \
    # Configure conda
    $CONDA_DIR/bin/conda config --set auto_activate_base false && \
    $CONDA_DIR/bin/conda config --add channels conda-forge && \
    $CONDA_DIR/bin/conda config --set channel_priority strict

# Copy application files first
COPY --chown=$APP_USER:$APP_USER . $APP_HOME/

# Create conda environment from environment.yml
RUN . $CONDA_DIR/etc/profile.d/conda.sh && \
    # Create the environment
    conda env create -f $APP_HOME/environment.yml -n draw && \
    # Clean up
    conda clean --all -y && \
    # Initialize conda for the user
    echo "export PATH=$CONDA_DIR/bin:\$PATH" >> ~/.bashrc && \
    echo ". $CONDA_DIR/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate draw" >> ~/.bashrc

# Set environment for conda
ENV PATH=$CONDA_DIR/envs/draw/bin:$PATH
ENV CONDA_DEFAULT_ENV=draw
ENV CONDA_PREFIX=$CONDA_DIR/envs/$CONDA_DEFAULT_ENV

# Switch to root to create entrypoint script
USER root

# Create entrypoint script with proper permissions
RUN echo '#!/bin/bash\nset -e\n\n# Ensure EFS mount is writable by our user\nif [ -d "$EFS_MOUNT" ]; then\n    chown -R $APP_USER:$APP_USER "$EFS_MOUNT"\n    chmod 755 "$EFS_MOUNT"\nfi\n\n# Execute the main command\nexec "$@"' > /entrypoint.sh && \
    chmod 755 /entrypoint.sh && \
    chown $APP_USER:$APP_USER /entrypoint.sh

# Switch back to non-root user for runtime
USER $APP_USER

# Set the entrypoint and default command
ENTRYPOINT ["/entrypoint.sh"]
# The entrypoint script is already set up to run as the non-root user
CMD ["bash"]
