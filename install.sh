#!/bin/bash

# OCR Installation Script for Linux
# This script automates the installation and setup process

set -e  # Exit on error

echo "=========================================="
echo "OCR System Installation Script"
echo "=========================================="
echo ""

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Node.js installation parameters
NODE_VERSION="v24.14.0"
NODE_TARBALL="node-${NODE_VERSION}-linux-arm64.tar.xz"
NODE_INSTALL_DIR="$HOME/.local"

# Check if Node.js is already installed and version
echo "Step 0: Checking Node.js installation..."
if command -v node &> /dev/null
then
    CURRENT_NODE_VERSION=$(node -v)
    echo "Node.js is already installed: $CURRENT_NODE_VERSION"
    
    # Check if it's the correct version
    if [ "$CURRENT_NODE_VERSION" == "$NODE_VERSION" ]; then
        echo "✓ Node.js version is correct"
    else
        echo "⚠ Node.js version mismatch. Current: $CURRENT_NODE_VERSION, Required: $NODE_VERSION"
        read -p "Do you want to install Node.js $NODE_VERSION? (y/n) " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Check if tarball exists
            if [ -f "$NODE_TARBALL" ]; then
                echo "Found $NODE_TARBALL, extracting..."
                
                # Create installation directory
                mkdir -p "$NODE_INSTALL_DIR"
                
                # Extract Node.js
                tar -xJf "$NODE_TARBALL" -C "$NODE_INSTALL_DIR" --strip-components=1
                
                # Add to PATH if not already there
                if ! grep -q "$NODE_INSTALL_DIR/bin" ~/.bashrc; then
                    echo "" >> ~/.bashrc
                    echo "# Node.js $NODE_VERSION" >> ~/.bashrc
                    echo "export PATH=\"$NODE_INSTALL_DIR/bin:\$PATH\"" >> ~/.bashrc
                    echo "✓ Added Node.js to PATH in ~/.bashrc"
                fi
                
                # Export PATH for current session
                export PATH="$NODE_INSTALL_DIR/bin:$PATH"
                
                echo "✓ Node.js $NODE_VERSION installed successfully"
                echo "Installed location: $NODE_INSTALL_DIR"
            else
                echo "❌ Error: $NODE_TARBALL not found in current directory"
                echo "Please download Node.js v24.14.0 for Linux x64 and place it here"
                exit 1
            fi
        fi
    fi
else
    echo "Node.js is not installed."
    read -p "Do you want to install Node.js $NODE_VERSION? (y/n) " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Check if tarball exists
        if [ -f "$NODE_TARBALL" ]; then
            echo "Found $NODE_TARBALL, extracting..."
            
            # Create installation directory
            mkdir -p "$NODE_INSTALL_DIR"
            
            # Extract Node.js
            tar -xJf "$NODE_TARBALL" -C "$NODE_INSTALL_DIR" --strip-components=1
            
            # Add to PATH
            if ! grep -q "$NODE_INSTALL_DIR/bin" ~/.bashrc; then
                echo "" >> ~/.bashrc
                echo "# Node.js $NODE_VERSION" >> ~/.bashrc
                echo "export PATH=\"$NODE_INSTALL_DIR/bin:\$PATH\"" >> ~/.bashrc
                echo "✓ Added Node.js to PATH in ~/.bashrc"
            fi
            
            # Export PATH for current session
            export PATH="$NODE_INSTALL_DIR/bin:$PATH"
            
            echo "✓ Node.js $NODE_VERSION installed successfully"
            echo "Installed location: $NODE_INSTALL_DIR"
            
            # Verify installation
            echo "Node version: $(node -v)"
            echo "NPM version: $(npm -v)"
        else
            echo "❌ Error: $NODE_TARBALL not found in current directory"
            echo "Please download Node.js v24.14.0 for Linux ARM64 and place it here"
            exit 1
        fi
    else
        echo "Skipping Node.js installation"
    fi
fi
echo ""

echo "Step 0.5: Installing and configuring Redis server..."
if command -v redis-server &> /dev/null
then
    echo "Redis is already installed: $(redis-server --version)"
    read -p "Do you want to reinstall Redis? (y/N): " reinstall_redis
    if [[ $reinstall_redis =~ ^[Yy]$ ]]; then
        echo "Reinstalling Redis server..."
        sudo apt-get update
        sudo apt-get install -y --reinstall redis-server
        echo "✓ Redis server reinstalled"
    fi
else
    read -p "Redis is not installed. Install now? (Y/n): " install_redis
    if [[ ! $install_redis =~ ^[Nn]$ ]]; then
        echo "Installing Redis server..."
        sudo apt-get update
        sudo apt-get install -y redis-server
        echo "✓ Redis server installed"
    else
        echo "⚠ Skipping Redis installation. Note: Application requires Redis to function!"
    fi
fi

# Start and enable Redis service
if command -v redis-server &> /dev/null
then
    echo "Starting Redis service..."
    sudo systemctl start redis-server
    sudo systemctl enable redis-server
    echo "✓ Redis service started and enabled"
    
    # Test Redis connection
    if redis-cli ping &> /dev/null
    then
        echo "✓ Redis is running and responding to ping"
    else
        echo "⚠ Warning: Redis might not be running properly"
    fi
fi
echo ""

echo "Step 1: Cleaning npm cache..."
npm cache clean --force
echo "✓ Cache cleaned"
echo ""

echo "Step 2: Installing dependencies..."
# per-site settings live in config.json, which git does not track.
# A fresh device starts from the example; an existing one keeps its own.
if [ ! -f config.json ] && [ -f config.example.json ]; then
    cp config.example.json config.json
    echo "created config.json from config.example.json"
fi

npm install --prefer-offline --no-audit --legacy-peer-deps
echo "✓ Dependencies installed"
echo ""

echo "Step 3: Setting execute permissions for node modules..."
chmod +x node_modules/.bin/*
echo "✓ Permissions set"
echo ""

echo "Step 4: Building the project..."
npm run build
echo "✓ Build completed"
echo ""

echo "Step 4.5: Installing Python dependencies..."
# Check if Python 3 is installed
if command -v python3 &> /dev/null
then
    echo "Python 3 is installed: $(python3 --version)"
    
    # Check if requirements.txt exists
    if [ -f "requirements.txt" ]; then
        echo "Installing Python packages from requirements.txt..."
        # Debian bookworm needs --break-system-packages; keep install non-fatal
        python3 -m pip install --break-system-packages -r requirements.txt \
            || python3 -m pip install --user -r requirements.txt \
            || echo "⚠ Warning: pip install failed - install manually: pip3 install --break-system-packages -r requirements.txt"
        echo "✓ Python dependencies step finished"
    else
        echo "⚠ Warning: requirements.txt not found, skipping Python dependencies"
    fi
else
    echo "⚠ Warning: Python 3 is not installed"
    echo "To install Python 3, run: sudo apt-get install python3 python3-pip"
fi
echo ""

echo "Step 4.8: Creating .env if missing..."
# .env is gitignored - fresh clones need one
if [ ! -f ".env" ] && [ -f ".env.example" ]; then
    cp .env.example .env
    echo "✓ Created .env from .env.example"
else
    echo "✓ .env already present"
fi
echo ""

echo "Step 5: Setting up PM2..."

# Configure npm to install global packages without sudo
NPM_PREFIX="$HOME/.npm-global"
mkdir -p "$NPM_PREFIX"
npm config set prefix "$NPM_PREFIX"

# Add npm global bin to PATH if not already there
if ! grep -q ".npm-global/bin" ~/.bashrc; then
    echo "" >> ~/.bashrc
    echo "# NPM Global packages" >> ~/.bashrc
    echo "export PATH=\"$NPM_PREFIX/bin:\$PATH\"" >> ~/.bashrc
fi

# Export PATH for current session
export PATH="$NPM_PREFIX/bin:$PATH"

# Check if PM2 is installed
if ! command -v pm2 &> /dev/null
then
    echo "PM2 is not installed. Installing PM2 globally (without sudo)..."
    npm install -g pm2
    echo "✓ PM2 installed to $NPM_PREFIX"
else
    echo "✓ PM2 is already installed"
fi
echo ""

# Stop and delete existing processes from ecosystem
echo "Step 6: Cleaning up existing PM2 processes..."
if pm2 list | grep -q "ocr"; then
    echo "Stopping existing 'ocr' process..."
    pm2 stop ocr 2>/dev/null || true
    pm2 delete ocr 2>/dev/null || true
    echo "✓ Existing process cleaned"
else
    echo "✓ No existing process found"
fi
echo ""

echo "Step 7: Starting application with PM2..."
pm2 start ecosystem.config.js
echo "✓ Application started"
echo ""

echo "Step 8: Configuring PM2 startup (auto-start on boot)..."
# Get the PM2 startup command
STARTUP_CMD=$(pm2 startup | grep "sudo env" | cut -d' ' -f2-)

if [ -n "$STARTUP_CMD" ]; then
    echo "Running PM2 startup command..."
    echo "Command: $STARTUP_CMD"
    
    # Execute the startup command with sudo
    eval "sudo $STARTUP_CMD"
    
    if [ $? -eq 0 ]; then
        echo "✓ PM2 startup configured successfully"
        
        # Save PM2 process list
        echo "Saving PM2 configuration..."
        pm2 save --force
        echo "✓ PM2 configuration saved"
    else
        echo "⚠ Warning: PM2 startup configuration failed"
        echo "You may need to run it manually:"
        echo "  pm2 startup"
        echo "  Then run the command shown with sudo"
        echo "  Finally: pm2 save"
    fi
else
    echo "⚠ Warning: Could not get PM2 startup command"
    echo "Please run manually:"
    echo "  pm2 startup"
    echo "  Then run the command shown with sudo"
    echo "  Finally: pm2 save"
fi
echo ""

echo "=========================================="
echo "Installation completed successfully!"
echo "=========================================="
echo ""
echo "✓ Node.js installed"
echo "✓ Dependencies installed"
echo "✓ Project built"
echo "✓ PM2 configured"
echo "✓ Application started"
echo "✓ Auto-startup enabled (on boot)"
echo ""
echo "Application is now running at: http://YOUR_IP:64010"
echo ""
echo "Useful commands:"
echo "  pm2 status        - View application status"
echo "  pm2 logs ocr      - View logs"
echo "  pm2 restart ocr   - Restart application"
echo "  pm2 stop ocr      - Stop application"
echo "  pm2 monit         - Monitor in real-time"
echo ""
echo "Installation complete! The system will auto-start on reboot."
echo ""
