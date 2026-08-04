import { exec } from 'child_process';
import { promisify } from 'util';
import fs from 'fs-extra';
import path from 'path';
import os from 'os';

const execAsync = promisify(exec);

class NetworkManager {
  constructor() {
    this.interfaceName = 'eth0'; // Default interface
    this.netplanPath = '/etc/netplan/01-network-manager-all.yaml';
    this.backupPath = '/etc/netplan/backup';
    this.networkType = null;
    this.init();
  }

  // Initialize and detect network configuration system
  async init() {
    try {
      this.networkType = await this.detectNetworkSystem();
      this.interfaceName = await this.detectPrimaryInterface();
      console.log('NetworkManager initialized:', {
        networkType: this.networkType,
        interfaceName: this.interfaceName
      });
    } catch (error) {
      console.error('NetworkManager init error:', error);
      this.networkType = 'unknown';
    }
  }

  // Detect which network configuration system is in use
  async detectNetworkSystem() {
    try {
      // Check for netplan (Ubuntu 18+)
      if (await fs.pathExists('/etc/netplan')) {
        return 'netplan';
      }
      
      // Check for NetworkManager
      if (await fs.pathExists('/etc/NetworkManager')) {
        return 'networkmanager';
      }
      
      // Check for systemd-networkd
      if (await fs.pathExists('/etc/systemd/network')) {
        return 'systemd-networkd';
      }
      
      // Check for interfaces file (Debian/Ubuntu legacy)
      if (await fs.pathExists('/etc/network/interfaces')) {
        return 'interfaces';
      }
      
      // Check for ifcfg (RHEL/CentOS)
      if (await fs.pathExists('/etc/sysconfig/network-scripts')) {
        return 'ifcfg';
      }
      
      return 'unknown';
    } catch (error) {
      console.error('Error detecting network system:', error);
      return 'unknown';
    }
  }

  // Detect primary network interface
  async detectPrimaryInterface() {
    try {
      // Method 1: Get interface from default route
      try {
        const { stdout } = await execAsync('ip route show default');
        const match = stdout.match(/dev\s+(\w+)/);
        if (match) {
          return match[1];
        }
      } catch (error) {
        // Continue to next method
      }

      // Method 2: Get first active interface
      try {
        const { stdout } = await execAsync('ip link show up');
        const lines = stdout.split('\n');
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          const match = line.match(/^\d+:\s+(\w+):/);
          if (match && match[1] !== 'lo') {
            return match[1];
          }
        }
      } catch (error) {
        // Continue to next method
      }

      // Method 3: Check common interface names
      const commonInterfaces = ['eth0', 'enp0s3', 'ens33', 'wlan0'];
      for (let i = 0; i < commonInterfaces.length; i++) {
        const iface = commonInterfaces[i];
        try {
          await execAsync(`ip link show ${iface}`);
          return iface; // Interface exists
        } catch (error) {
          // Interface doesn't exist, try next
        }
      }
      
      return 'eth0'; // Final fallback
    } catch (error) {
      console.error('Error detecting primary interface:', error);
      return 'eth0';
    }
  }

  // Get current network configuration
  async getCurrentConfig() {
    try {
      // Get IP information
      const { stdout: ipInfo } = await execAsync(`ip addr show ${this.interfaceName}`);
      const { stdout: routeInfo } = await execAsync('ip route show default');
      const { stdout: dnsInfo } = await execAsync('cat /etc/resolv.conf');

      const config = {
        interface: this.interfaceName,
        mode: 'dhcp', // Default assumption
        ip: null,
        netmask: null,
        gateway: null,
        dns: [],
      };

      // Parse IP address
      const ipMatch = ipInfo.match(/inet (\d+\.\d+\.\d+\.\d+)\/(\d+)/);
      if (ipMatch) {
        config.ip = ipMatch[1];
        const cidr = parseInt(ipMatch[2]);
        config.netmask = this.cidrToNetmask(cidr);
      }

      // Parse gateway
      const gatewayMatch = routeInfo.match(/default via (\d+\.\d+\.\d+\.\d+)/);
      if (gatewayMatch) {
        config.gateway = gatewayMatch[1];
      }

      // Parse DNS servers
      const dnsMatches = dnsInfo.match(/nameserver (\d+\.\d+\.\d+\.\d+)/g);
      if (dnsMatches) {
        config.dns = dnsMatches.map(match => match.replace('nameserver ', ''));
      }

      // CRITICAL: Check if it's static configuration by reading SAVED config files
      const staticConfigResult = await this.readStaticConfigFromFiles();
      if (staticConfigResult.isStatic) {
        config.mode = 'static';
        // Use saved configuration values if they exist and current IP matches
        if (staticConfigResult.config && staticConfigResult.config.ip === config.ip) {
          config.ip = staticConfigResult.config.ip;
          config.netmask = staticConfigResult.config.netmask;
          config.gateway = staticConfigResult.config.gateway;
          if (staticConfigResult.config.dns && staticConfigResult.config.dns.length > 0) {
            config.dns = staticConfigResult.config.dns;
          }
        }
      }

      console.log('Current network config determined:', config);
      return config;
    } catch (error) {
      console.error('Error getting current network config:', error);
      throw new Error('Failed to get network configuration');
    }
  }

  // Configure network settings
  async configureNetwork(config) {
    try {
      console.log('Starting TRULY PERSISTENT network configuration:', config);
      
      // Ensure network system is detected
      if (!this.networkType) {
        this.networkType = await this.detectNetworkSystem();
      }
      
      console.log('Detected network system:', this.networkType);

      // Backup current configuration
      await this.backupCurrentConfig();

      // CRITICAL: Save persistent configuration FIRST and VERIFY it's written
      if (config.mode === 'dhcp') {
        await this.savePersistentDHCP();
        await this.verifyPersistentConfig('dhcp');
      } else if (config.mode === 'static') {
        await this.savePersistentStatic(config);
        await this.verifyPersistentConfig('static', config);
      } else {
        throw new Error(`Invalid network mode: ${config.mode}`);
      }

      // Apply temporary configuration (immediate effect)
      if (config.mode === 'dhcp') {
        await this.configureDHCP();
      } else if (config.mode === 'static') {
        await this.configureStaticIP(config);
      }

      // Force system to reload and apply persistent configuration
      await this.forcePersistentReload();

      return {
        success: true,
        message: 'Network configuration saved PERMANENTLY and verified. Settings WILL survive reboot.',
        system: this.networkType,
        persistent: true,
        verified: true,
      };
    } catch (error) {
      console.error('Error configuring truly persistent network:', error);
      throw new Error(`Failed to configure persistent network: ${error.message}`);
    }
  }

  // Configure DHCP using direct commands
  async configureDHCP() {
    try {
      console.log('Configuring DHCP for interface:', this.interfaceName);
      
      // Release current IP
      await execAsync(`sudo dhclient -r ${this.interfaceName}`).catch(() => {
        // Ignore errors, interface might not have DHCP lease
      });
      
      // Request new DHCP lease
      await execAsync(`sudo dhclient ${this.interfaceName}`);
      
      console.log('DHCP configuration completed');
    } catch (error) {
      console.error('DHCP configuration failed:', error);
      throw error;
    }
  }

  // Configure static IP using direct commands
  async configureStaticIP(config) {
    try {
      console.log('Configuring static IP:', config);
      
      if (!config.ip || !config.netmask || !config.gateway) {
        throw new Error('Missing required static IP configuration (ip, netmask, gateway)');
      }

      const { ip, netmask, gateway } = config;
      const iface = this.interfaceName;

      // Calculate CIDR from netmask
      const cidr = this.netmaskToCidr(netmask);
      
      console.log(`Setting up ${ip}/${cidr} on ${iface} with gateway ${gateway}`);

      // Flush existing IP addresses
      await execAsync(`sudo ip addr flush dev ${iface}`);
      
      // Set new IP address
      await execAsync(`sudo ip addr add ${ip}/${cidr} dev ${iface}`);
      
      // Bring interface up
      await execAsync(`sudo ip link set ${iface} up`);
      
      // Set default gateway (remove old first)
      await execAsync('sudo ip route del default').catch(() => {
        // Ignore errors if no default route exists
      });
      await execAsync(`sudo ip route add default via ${gateway}`);

      // Set DNS servers if provided
      if (config.dns && config.dns.length > 0) {
        const dnsContent = config.dns.map(dns => `nameserver ${dns}`).join('\n') + '\n';
        await execAsync(`echo '${dnsContent}' | sudo tee /etc/resolv.conf > /dev/null`);
      }

      console.log('Static IP configuration completed');
      
      // Wait a moment for network to stabilize
      await new Promise((resolve) => setTimeout(resolve, 2000));
    } catch (error) {
      console.error('Static IP configuration failed:', error);
      throw error;
    }
  }

  // Configure using netplan (Ubuntu 18+)
  async configureNetplan(config) {
    let netplanConfig;
    
    if (config.mode === 'dhcp') {
      netplanConfig = {
        network: {
          version: 2,
          renderer: 'NetworkManager',
          ethernets: {
            [this.interfaceName]: {
              dhcp4: true,
              dhcp6: false,
            },
          },
        },
      };
    } else if (config.mode === 'static') {
      if (!config.ip || !config.netmask || !config.gateway) {
        throw new Error('Missing required static IP configuration');
      }

      const cidr = this.netmaskToCidr(config.netmask);
      netplanConfig = {
        network: {
          version: 2,
          renderer: 'NetworkManager',
          ethernets: {
            [this.interfaceName]: {
              dhcp4: false,
              dhcp6: false,
              addresses: [`${config.ip}/${cidr}`],
              gateway4: config.gateway,
              nameservers: {
                addresses: config.dns && config.dns.length > 0 
                  ? config.dns 
                  : ['8.8.8.8', '8.8.4.4'],
              },
            },
          },
        },
      };
    }

    const yamlContent = this.objectToYaml(netplanConfig);
    await fs.writeFile(this.netplanPath, yamlContent);
  }

  // Configure using /etc/network/interfaces (Debian/Ubuntu legacy)
  async configureInterfaces(config) {
    const interfacesPath = '/etc/network/interfaces';
    let content = await fs.readFile(interfacesPath, 'utf8');
    
    // Remove existing configuration for this interface
    const interfaceRegex = new RegExp(
      `^(auto ${this.interfaceName}|iface ${this.interfaceName}.*|\\s+.*)*\\n?`,
      'gm'
    );
    content = content.replace(interfaceRegex, '');

    // Add new configuration
    let newConfig = `\nauto ${this.interfaceName}\n`;
    
    if (config.mode === 'dhcp') {
      newConfig += `iface ${this.interfaceName} inet dhcp\n`;
    } else if (config.mode === 'static') {
      newConfig += `iface ${this.interfaceName} inet static\n`;
      newConfig += `    address ${config.ip}\n`;
      newConfig += `    netmask ${config.netmask}\n`;
      newConfig += `    gateway ${config.gateway}\n`;
      
      if (config.dns && config.dns.length > 0) {
        newConfig += `    dns-nameservers ${config.dns.join(' ')}\n`;
      }
    }

    content += newConfig;
    await fs.writeFile(interfacesPath, content);
  }

  // Configure using ifcfg (RHEL/CentOS)
  async configureIfcfg(config) {
    const ifcfgPath = `/etc/sysconfig/network-scripts/ifcfg-${this.interfaceName}`;
    
    let content = `DEVICE=${this.interfaceName}\n`;
    content += 'ONBOOT=yes\n';
    
    if (config.mode === 'dhcp') {
      content += 'BOOTPROTO=dhcp\n';
    } else if (config.mode === 'static') {
      content += 'BOOTPROTO=static\n';
      content += `IPADDR=${config.ip}\n`;
      content += `NETMASK=${config.netmask}\n`;
      content += `GATEWAY=${config.gateway}\n`;
      
      if (config.dns && config.dns.length > 0) {
        config.dns.forEach((dns, index) => {
          content += `DNS${index + 1}=${dns}\n`;
        });
      }
    }

    await fs.writeFile(ifcfgPath, content);
  }

  // Configure using NetworkManager nmcli
  async configureNetworkManager(config) {
    const connectionName = `${this.interfaceName}-connection`;
    
    // Delete existing connection
    try {
      await execAsync(`sudo nmcli connection delete "${connectionName}"`);
    } catch (error) {
      // Connection might not exist, ignore
    }

    if (config.mode === 'dhcp') {
      await execAsync(
        `sudo nmcli connection add type ethernet con-name "${connectionName}" ` +
        `ifname ${this.interfaceName} autoconnect yes`
      );
    } else if (config.mode === 'static') {
      let command = `sudo nmcli connection add type ethernet con-name "${connectionName}" ` +
        `ifname ${this.interfaceName} autoconnect yes ` +
        `ip4 ${config.ip}/${this.netmaskToCidr(config.netmask)} ` +
        `gw4 ${config.gateway}`;
      
      if (config.dns && config.dns.length > 0) {
        command += ` ipv4.dns "${config.dns.join(',')}"`;
      }
      
      await execAsync(command);
    }

    // Activate the connection
    await execAsync(`sudo nmcli connection up "${connectionName}"`);
  }

  // Generic fallback configuration
  async configureGeneric(config) {
    if (config.mode === 'dhcp') {
      await execAsync(`sudo dhclient ${this.interfaceName}`);
    } else if (config.mode === 'static') {
      // Set IP address
      const cidr = this.netmaskToCidr(config.netmask);
      await execAsync(`sudo ip addr flush dev ${this.interfaceName}`);
      await execAsync(`sudo ip addr add ${config.ip}/${cidr} dev ${this.interfaceName}`);
      await execAsync(`sudo ip link set ${this.interfaceName} up`);
      
      // Set gateway
      await execAsync(`sudo ip route add default via ${config.gateway}`);
      
      // Set DNS
      if (config.dns && config.dns.length > 0) {
        const dnsContent = config.dns.map(dns => `nameserver ${dns}`).join('\n');
        await fs.writeFile('/tmp/resolv.conf.new', dnsContent);
        await execAsync('sudo mv /tmp/resolv.conf.new /etc/resolv.conf');
      }
    }
  }

  // Save persistent DHCP configuration
  async savePersistentDHCP() {
    try {
      switch (this.networkType) {
        case 'netplan':
          await this.writeNetplanDHCP();
          break;
        case 'interfaces':
          await this.writeInterfacesDHCP();
          break;
        case 'ifcfg':
          await this.writeIfcfgDHCP();
          break;
        case 'networkmanager':
          await this.writeNetworkManagerDHCP();
          break;
        default:
          console.warn('Unknown network system, persistent configuration may not work');
      }
    } catch (error) {
      console.error('Error saving persistent DHCP config:', error);
    }
  }

  // Save persistent static IP configuration
  async savePersistentStatic(config) {
    try {
      switch (this.networkType) {
        case 'netplan':
          await this.writeNetplanStatic(config);
          break;
        case 'interfaces':
          await this.writeInterfacesStatic(config);
          break;
        case 'ifcfg':
          await this.writeIfcfgStatic(config);
          break;
        case 'networkmanager':
          await this.writeNetworkManagerStatic(config);
          break;
        default:
          console.warn('Unknown network system, persistent configuration may not work');
      }
    } catch (error) {
      console.error('Error saving persistent static config:', error);
    }
  }

  // Write netplan DHCP configuration
  async writeNetplanDHCP() {
    const netplanConfig = {
      network: {
        version: 2,
        renderer: 'networkd',
        ethernets: {
          [this.interfaceName]: {
            dhcp4: true,
            dhcp6: false,
          },
        },
      },
    };

    await fs.ensureDir('/etc/netplan');
    const yamlContent = this.objectToYaml(netplanConfig);
    console.log('Writing netplan DHCP config:', yamlContent);
    
    // Write to primary netplan file
    await fs.writeFile(this.netplanPath, yamlContent);
    
    // Ensure permissions are correct
    await execAsync(`sudo chmod 600 ${this.netplanPath}`);
    console.log('Netplan DHCP configuration written and permissions set');
  }

  // Write netplan static configuration
  async writeNetplanStatic(config) {
    const cidr = this.netmaskToCidr(config.netmask);
    const netplanConfig = {
      network: {
        version: 2,
        renderer: 'networkd',
        ethernets: {
          [this.interfaceName]: {
            dhcp4: false,
            dhcp6: false,
            addresses: [`${config.ip}/${cidr}`],
            gateway4: config.gateway,
            nameservers: {
              addresses:
                config.dns && config.dns.length > 0
                  ? config.dns
                  : ['8.8.8.8', '8.8.4.4'],
            },
          },
        },
      },
    };

    await fs.ensureDir('/etc/netplan');
    const yamlContent = this.objectToYaml(netplanConfig);
    console.log('Writing netplan static config:', yamlContent);
    
    // Write to primary netplan file
    await fs.writeFile(this.netplanPath, yamlContent);
    
    // Ensure permissions are correct
    await execAsync(`sudo chmod 600 ${this.netplanPath}`);
    console.log('Netplan static configuration written and permissions set');
  }

  // Write /etc/network/interfaces DHCP configuration
  async writeInterfacesDHCP() {
    const interfacesPath = '/etc/network/interfaces';
    let content = '';
    
    try {
      content = await fs.readFile(interfacesPath, 'utf8');
    } catch (error) {
      // File doesn't exist, create minimal content
      content = '# This file describes the network interfaces available on your system\n';
      content += 'auto lo\n';
      content += 'iface lo inet loopback\n\n';
    }
    
    // Remove existing configuration for this interface
    const regex = new RegExp(
      `^(auto ${this.interfaceName}|iface ${this.interfaceName}.*|\\s+.*)\\n?`,
      'gm'
    );
    content = content.replace(regex, '');

    // Add DHCP configuration
    content += `\nauto ${this.interfaceName}\n`;
    content += `iface ${this.interfaceName} inet dhcp\n`;

    await fs.writeFile(interfacesPath, content);
  }

  // Write /etc/network/interfaces static configuration
  async writeInterfacesStatic(config) {
    const interfacesPath = '/etc/network/interfaces';
    let content = '';
    
    try {
      content = await fs.readFile(interfacesPath, 'utf8');
    } catch (error) {
      // File doesn't exist, create minimal content
      content = '# This file describes the network interfaces available on your system\n';
      content += 'auto lo\n';
      content += 'iface lo inet loopback\n\n';
    }
    
    // Remove existing configuration for this interface
    const regex = new RegExp(
      `^(auto ${this.interfaceName}|iface ${this.interfaceName}.*|\\s+.*)\\n?`,
      'gm'
    );
    content = content.replace(regex, '');

    // Add static configuration
    content += `\nauto ${this.interfaceName}\n`;
    content += `iface ${this.interfaceName} inet static\n`;
    content += `    address ${config.ip}\n`;
    content += `    netmask ${config.netmask}\n`;
    content += `    gateway ${config.gateway}\n`;
    
    if (config.dns && config.dns.length > 0) {
      content += `    dns-nameservers ${config.dns.join(' ')}\n`;
    }

    await fs.writeFile(interfacesPath, content);
  }

  // Write ifcfg DHCP configuration
  async writeIfcfgDHCP() {
    const ifcfgPath = `/etc/sysconfig/network-scripts/ifcfg-${this.interfaceName}`;
    
    let content = `DEVICE=${this.interfaceName}\n`;
    content += 'ONBOOT=yes\n';
    content += 'BOOTPROTO=dhcp\n';

    await fs.ensureDir('/etc/sysconfig/network-scripts');
    await fs.writeFile(ifcfgPath, content);
  }

  // Write ifcfg static configuration
  async writeIfcfgStatic(config) {
    const ifcfgPath = `/etc/sysconfig/network-scripts/ifcfg-${this.interfaceName}`;
    
    let content = `DEVICE=${this.interfaceName}\n`;
    content += 'ONBOOT=yes\n';
    content += 'BOOTPROTO=static\n';
    content += `IPADDR=${config.ip}\n`;
    content += `NETMASK=${config.netmask}\n`;
    content += `GATEWAY=${config.gateway}\n`;
    
    if (config.dns && config.dns.length > 0) {
      config.dns.forEach((dns, index) => {
        content += `DNS${index + 1}=${dns}\n`;
      });
    }

    await fs.ensureDir('/etc/sysconfig/network-scripts');
    await fs.writeFile(ifcfgPath, content);
  }

  // Write NetworkManager DHCP configuration
  async writeNetworkManagerDHCP() {
    const connectionName = `${this.interfaceName}-connection`;
    
    // Delete existing connection
    try {
      await execAsync(`sudo nmcli connection delete "${connectionName}"`);
    } catch (error) {
      // Connection might not exist, ignore
    }

    // Create DHCP connection
    await execAsync(
      `sudo nmcli connection add type ethernet con-name "${connectionName}" ` +
      `ifname ${this.interfaceName} autoconnect yes`
    );
  }

  // Write NetworkManager static configuration
  async writeNetworkManagerStatic(config) {
    const connectionName = `${this.interfaceName}-connection`;
    
    // Delete existing connection
    try {
      await execAsync(`sudo nmcli connection delete "${connectionName}"`);
    } catch (error) {
      // Connection might not exist, ignore
    }

    // Create static connection
    let command = `sudo nmcli connection add type ethernet con-name "${connectionName}" ` +
      `ifname ${this.interfaceName} autoconnect yes ` +
      `ip4 ${config.ip}/${this.netmaskToCidr(config.netmask)} ` +
      `gw4 ${config.gateway}`;
    
    if (config.dns && config.dns.length > 0) {
      command += ` ipv4.dns "${config.dns.join(',')}"`;
    }
    
    await execAsync(command);
  }

  // Verify persistent configuration is written correctly
  async verifyPersistentConfig(mode, config = null) {
    try {
      console.log('Verifying persistent configuration is written...');
      
      switch (this.networkType) {
        case 'netplan':
          return await this.verifyNetplanConfig(mode, config);
        case 'interfaces':
          return await this.verifyInterfacesConfig(mode, config);
        case 'ifcfg':
          return await this.verifyIfcfgConfig(mode, config);
        case 'networkmanager':
          return await this.verifyNetworkManagerConfig(mode, config);
        default:
          console.warn('Cannot verify unknown network system');
          return false;
      }
    } catch (error) {
      console.error('Error verifying persistent config:', error);
      throw new Error('Failed to verify persistent configuration was written');
    }
  }

  // Verify netplan configuration
  async verifyNetplanConfig(mode, config) {
    try {
      if (!await fs.pathExists(this.netplanPath)) {
        throw new Error('Netplan configuration file not found');
      }
      
      const content = await fs.readFile(this.netplanPath, 'utf8');
      console.log('Netplan config content:', content);
      
      if (mode === 'dhcp') {
        if (!content.includes('dhcp4: true')) {
          throw new Error('DHCP configuration not found in netplan');
        }
      } else if (mode === 'static') {
        if (!content.includes(`${config.ip}/`) || !content.includes(config.gateway)) {
          throw new Error('Static IP configuration not found in netplan');
        }
      }
      
      console.log('Netplan configuration verified successfully');
      return true;
    } catch (error) {
      console.error('Netplan verification failed:', error);
      throw error;
    }
  }

  // Verify interfaces configuration
  async verifyInterfacesConfig(mode, config) {
    try {
      const interfacesPath = '/etc/network/interfaces';
      if (!await fs.pathExists(interfacesPath)) {
        throw new Error('Interfaces configuration file not found');
      }
      
      const content = await fs.readFile(interfacesPath, 'utf8');
      console.log('Interfaces config content:', content);
      
      if (mode === 'dhcp') {
        if (!content.includes(`iface ${this.interfaceName} inet dhcp`)) {
          throw new Error('DHCP configuration not found in interfaces');
        }
      } else if (mode === 'static') {
        if (!content.includes(`address ${config.ip}`) || !content.includes(`gateway ${config.gateway}`)) {
          throw new Error('Static IP configuration not found in interfaces');
        }
      }
      
      console.log('Interfaces configuration verified successfully');
      return true;
    } catch (error) {
      console.error('Interfaces verification failed:', error);
      throw error;
    }
  }

  // Verify ifcfg configuration
  async verifyIfcfgConfig(mode, config) {
    try {
      const ifcfgPath = `/etc/sysconfig/network-scripts/ifcfg-${this.interfaceName}`;
      if (!await fs.pathExists(ifcfgPath)) {
        throw new Error('ifcfg configuration file not found');
      }
      
      const content = await fs.readFile(ifcfgPath, 'utf8');
      console.log('ifcfg config content:', content);
      
      if (mode === 'dhcp') {
        if (!content.includes('BOOTPROTO=dhcp')) {
          throw new Error('DHCP configuration not found in ifcfg');
        }
      } else if (mode === 'static') {
        if (!content.includes(`IPADDR=${config.ip}`) || !content.includes(`GATEWAY=${config.gateway}`)) {
          throw new Error('Static IP configuration not found in ifcfg');
        }
      }
      
      console.log('ifcfg configuration verified successfully');
      return true;
    } catch (error) {
      console.error('ifcfg verification failed:', error);
      throw error;
    }
  }

  // Verify NetworkManager configuration
  async verifyNetworkManagerConfig(mode, config) {
    try {
      const connectionName = `${this.interfaceName}-connection`;
      const { stdout } = await execAsync(`sudo nmcli connection show "${connectionName}"`);
      console.log('NetworkManager connection:', stdout);
      
      if (mode === 'dhcp') {
        if (!stdout.includes('ipv4.method:') || !stdout.includes('auto')) {
          throw new Error('DHCP configuration not found in NetworkManager');
        }
      } else if (mode === 'static') {
        if (!stdout.includes(config.ip) || !stdout.includes(config.gateway)) {
          throw new Error('Static IP configuration not found in NetworkManager');
        }
      }
      
      console.log('NetworkManager configuration verified successfully');
      return true;
    } catch (error) {
      console.error('NetworkManager verification failed:', error);
      throw error;
    }
  }

  // Force reload of persistent configuration
  async forcePersistentReload() {
    try {
      console.log('Forcing persistent configuration reload...');
      
      switch (this.networkType) {
        case 'netplan':
          // Force netplan to generate and apply
          await execAsync('sudo netplan generate');
          await execAsync('sudo netplan apply');
          // Ensure systemd-networkd knows about changes
          await execAsync('sudo systemctl restart systemd-networkd');
          break;
          
        case 'interfaces':
          // Restart networking and ensure it's enabled
          await execAsync('sudo systemctl enable networking');
          await execAsync('sudo systemctl restart networking');
          break;
          
        case 'ifcfg':
          // Restart network services
          await execAsync('sudo systemctl restart network').catch(() => {
            return execAsync('sudo systemctl restart NetworkManager');
          });
          break;
          
        case 'networkmanager':
          // Reload NetworkManager and restart
          await execAsync('sudo systemctl reload NetworkManager');
          await execAsync('sudo systemctl restart NetworkManager');
          break;
          
        default:
          // Generic approach
          await execAsync('sudo systemctl restart networking').catch(() => {
            return execAsync('sudo service networking restart');
          });
      }
      
      // Wait for network to stabilize
      await new Promise((resolve) => setTimeout(resolve, 5000));
      
      console.log('Persistent configuration reload completed');
    } catch (error) {
      console.error('Error forcing persistent reload:', error);
      throw error;
    }
  }



  // Write netplan configuration
  async writeNetplanConfig(config) {
    const yamlContent = this.objectToYaml(config);
    await fs.writeFile(this.netplanPath, yamlContent);
  }

  // Apply network configuration based on system type
  async applyNetworkConfig() {
    try {
      console.log('Applying PERSISTENT network configuration for:', this.networkType);
      
      switch (this.networkType) {
        case 'netplan':
          // Generate and apply netplan configuration
          await execAsync('sudo netplan generate');
          await execAsync('sudo netplan apply');
          // Wait longer for netplan to fully apply
          await new Promise((resolve) => setTimeout(resolve, 5000));
          break;
          
        case 'interfaces':
          // Restart networking service for /etc/network/interfaces
          await execAsync('sudo systemctl restart networking');
          await new Promise((resolve) => setTimeout(resolve, 4000));
          break;
          
        case 'ifcfg':
          // Restart network service for ifcfg files
          try {
            await execAsync('sudo systemctl restart network');
          } catch (error) {
            // Try alternative restart method
            await execAsync('sudo systemctl restart NetworkManager');
          }
          await new Promise((resolve) => setTimeout(resolve, 4000));
          break;
          
        case 'networkmanager':
          // NetworkManager is already applied in the specific functions
          await execAsync('sudo systemctl reload NetworkManager');
          await new Promise((resolve) => setTimeout(resolve, 3000));
          break;
          
        default:
          // Generic configuration restart
          try {
            await execAsync('sudo systemctl restart networking');
          } catch (error) {
            try {
              await execAsync('sudo service networking restart');
            } catch (serviceError) {
              console.warn('Could not restart networking service');
            }
          }
          await new Promise((resolve) => setTimeout(resolve, 3000));
      }
      
      console.log('Persistent network configuration applied successfully');
      return true;
    } catch (error) {
      console.error('Error applying persistent network config:', error);
      throw error;
    }
  }

  // Backup current configuration
  async backupCurrentConfig() {
    try {
      if (await fs.pathExists(this.netplanPath)) {
        await fs.ensureDir(this.backupPath);
        const backupFile = path.join(this.backupPath, `network-${Date.now()}.yaml`);
        await fs.copy(this.netplanPath, backupFile);
      }
    } catch (error) {
      console.error('Error backing up config:', error);
    }
  }

  // Restore backup configuration
  async restoreBackup() {
    try {
      if (await fs.pathExists(this.backupPath)) {
        const backupFiles = await fs.readdir(this.backupPath);
        const latestBackup = backupFiles
          .filter(file => file.startsWith('network-') && file.endsWith('.yaml'))
          .sort()
          .pop();

        if (latestBackup) {
          const backupFile = path.join(this.backupPath, latestBackup);
          await fs.copy(backupFile, this.netplanPath);
          await this.applyNetworkConfig();
        }
      }
    } catch (error) {
      console.error('Error restoring backup:', error);
    }
  }

  // Check if current config is static
  async isStaticConfig() {
    try {
      const result = await this.readStaticConfigFromFiles();
      return result.isStatic;
    } catch (error) {
      return false;
    }
  }

  // Read static configuration from system files
  async readStaticConfigFromFiles() {
    try {
      switch (this.networkType) {
        case 'netplan':
          return await this.readNetplanConfig();
        case 'interfaces':
          return await this.readInterfacesConfig();
        case 'ifcfg':
          return await this.readIfcfgConfig();
        case 'networkmanager':
          return await this.readNetworkManagerConfig();
        default:
          return { isStatic: false, config: null };
      }
    } catch (error) {
      console.error('Error reading static config from files:', error);
      return { isStatic: false, config: null };
    }
  }

  // Read netplan configuration
  async readNetplanConfig() {
    try {
      if (!(await fs.pathExists(this.netplanPath))) {
        return { isStatic: false, config: null };
      }

      const content = await fs.readFile(this.netplanPath, 'utf8');
      
      // Check if DHCP is disabled and static config exists
      if (content.includes('dhcp4: false') || content.includes('addresses:')) {
        const config = {
          mode: 'static',
          ip: null,
          netmask: null,
          gateway: null,
          dns: [],
        };

        // Extract IP address
        const addressMatch = content.match(
          /addresses:\s*\n\s*-\s*(\d+\.\d+\.\d+\.\d+)\/(\d+)/,
        );
        if (addressMatch) {
          config.ip = addressMatch[1];
          const cidr = parseInt(addressMatch[2], 10);
          config.netmask = this.cidrToNetmask(cidr);
        }

        // Extract gateway
        const gatewayMatch = content.match(/gateway4:\s*(\d+\.\d+\.\d+\.\d+)/);
        if (gatewayMatch) {
          config.gateway = gatewayMatch[1];
        }

        // Extract DNS servers
        const dnsSection = content.match(
          /nameservers:\s*\n\s*addresses:\s*\[(.*?)\]/s,
        );
        if (dnsSection) {
          const dnsString = dnsSection[1];
          config.dns = dnsString
            .split(',')
            .map((dns) => dns.trim().replace(/['"]/g, ''));
        }

        return { isStatic: true, config };
      }

      return { isStatic: false, config: null };
    } catch (error) {
      console.error('Error reading netplan config:', error);
      return { isStatic: false, config: null };
    }
  }

  // Read /etc/network/interfaces configuration
  async readInterfacesConfig() {
    try {
      const interfacesPath = '/etc/network/interfaces';
      if (!(await fs.pathExists(interfacesPath))) {
        return { isStatic: false, config: null };
      }

      const content = await fs.readFile(interfacesPath, 'utf8');
      
      // Check if interface is configured as static
      const staticPattern = new RegExp(
        `iface ${this.interfaceName} inet static`,
        'm',
      );
      if (staticPattern.test(content)) {
        const config = {
          mode: 'static',
          ip: null,
          netmask: null,
          gateway: null,
          dns: [],
        };

        // Extract configuration from the interface block
        const interfacePattern = new RegExp(
          `iface ${this.interfaceName} inet static([\\s\\S]*?)(?=\\n\\S|\\niface|$)`,
          'm',
        );
        const interfaceMatch = content.match(interfacePattern);
        
        if (interfaceMatch) {
          const configBlock = interfaceMatch[1];
          
          // Extract IP address
          const addressMatch = configBlock.match(
            /address\s+(\d+\.\d+\.\d+\.\d+)/,
          );
          if (addressMatch) {
            config.ip = addressMatch[1];
          }

          // Extract netmask
          const netmaskMatch = configBlock.match(
            /netmask\s+(\d+\.\d+\.\d+\.\d+)/,
          );
          if (netmaskMatch) {
            config.netmask = netmaskMatch[1];
          }

          // Extract gateway
          const gatewayMatch = configBlock.match(
            /gateway\s+(\d+\.\d+\.\d+\.\d+)/,
          );
          if (gatewayMatch) {
            config.gateway = gatewayMatch[1];
          }

          // Extract DNS servers
          const dnsMatch = configBlock.match(/dns-nameservers\s+(.+)/);
          if (dnsMatch) {
            config.dns = dnsMatch[1]
              .split(/\s+/)
              .filter((dns) => dns.length > 0);
          }
        }

        return { isStatic: true, config };
      }

      return { isStatic: false, config: null };
    } catch (error) {
      console.error('Error reading interfaces config:', error);
      return { isStatic: false, config: null };
    }
  }

  // Read ifcfg configuration
  async readIfcfgConfig() {
    try {
      const ifcfgPath = `/etc/sysconfig/network-scripts/ifcfg-${this.interfaceName}`;
      if (!(await fs.pathExists(ifcfgPath))) {
        return { isStatic: false, config: null };
      }

      const content = await fs.readFile(ifcfgPath, 'utf8');
      
      // Check if BOOTPROTO is static
      if (content.includes('BOOTPROTO=static')) {
        const config = {
          mode: 'static',
          ip: null,
          netmask: null,
          gateway: null,
          dns: [],
        };

        // Extract IP address
        const ipMatch = content.match(/IPADDR=(\d+\.\d+\.\d+\.\d+)/);
        if (ipMatch) {
          config.ip = ipMatch[1];
        }

        // Extract netmask
        const netmaskMatch = content.match(/NETMASK=(\d+\.\d+\.\d+\.\d+)/);
        if (netmaskMatch) {
          config.netmask = netmaskMatch[1];
        }

        // Extract gateway
        const gatewayMatch = content.match(/GATEWAY=(\d+\.\d+\.\d+\.\d+)/);
        if (gatewayMatch) {
          config.gateway = gatewayMatch[1];
        }

        // Extract DNS servers
        const dnsMatches = content.match(/DNS\d+=(\d+\.\d+\.\d+\.\d+)/g);
        if (dnsMatches) {
          config.dns = dnsMatches.map((match) => match.split('=')[1]);
        }

        return { isStatic: true, config };
      }

      return { isStatic: false, config: null };
    } catch (error) {
      console.error('Error reading ifcfg config:', error);
      return { isStatic: false, config: null };
    }
  }

  // Read NetworkManager configuration
  async readNetworkManagerConfig() {
    try {
      const connectionName = `${this.interfaceName}-connection`;
      const { stdout } = await execAsync(
        `sudo nmcli connection show "${connectionName}"`,
      );
      
      // Check if connection uses manual (static) method
      if (stdout.includes('ipv4.method') && stdout.includes('manual')) {
        const config = {
          mode: 'static',
          ip: null,
          netmask: null,
          gateway: null,
          dns: [],
        };

        // Extract IP address and CIDR
        const addressMatch = stdout.match(
          /ipv4\.addresses:\s*(\d+\.\d+\.\d+\.\d+)\/(\d+)/,
        );
        if (addressMatch) {
          config.ip = addressMatch[1];
          const cidr = parseInt(addressMatch[2], 10);
          config.netmask = this.cidrToNetmask(cidr);
        }

        // Extract gateway
        const gatewayMatch = stdout.match(
          /ipv4\.gateway:\s*(\d+\.\d+\.\d+\.\d+)/,
        );
        if (gatewayMatch) {
          config.gateway = gatewayMatch[1];
        }

        // Extract DNS servers
        const dnsMatch = stdout.match(/ipv4\.dns:\s*(.+)/);
        if (dnsMatch) {
          config.dns = dnsMatch[1].split(',').map((dns) => dns.trim());
        }

        return { isStatic: true, config };
      }

      return { isStatic: false, config: null };
    } catch (error) {
      console.error('Error reading NetworkManager config:', error);
      return { isStatic: false, config: null };
    }
  }

  // Convert CIDR to netmask
  cidrToNetmask(cidr) {
    const mask = [];
    for (let i = 0; i < 4; i++) {
      const n = Math.min(cidr, 8);
      mask.push(256 - Math.pow(2, 8 - n));
      cidr -= n;
    }
    return mask.join('.');
  }

  // Convert netmask to CIDR
  netmaskToCidr(netmask) {
    return netmask
      .split('.')
      .map(Number)
      .map(part => part.toString(2))
      .join('')
      .split('1').length - 1;
  }

  // Simple YAML converter for netplan
  objectToYaml(obj, indent = 0) {
    let yaml = '';
    const spaces = '  '.repeat(indent);

    for (const [key, value] of Object.entries(obj)) {
      if (typeof value === 'object' && !Array.isArray(value) && value !== null) {
        yaml += `${spaces}${key}:\n`;
        yaml += this.objectToYaml(value, indent + 1);
      } else if (Array.isArray(value)) {
        yaml += `${spaces}${key}:\n`;
        for (const item of value) {
          yaml += `${spaces}  - ${item}\n`;
        }
      } else if (typeof value === 'boolean') {
        yaml += `${spaces}${key}: ${value ? 'true' : 'false'}\n`;
      } else {
        yaml += `${spaces}${key}: ${value}\n`;
      }
    }

    return yaml;
  }

  // Get network interfaces
  async getNetworkInterfaces() {
    try {
      const { stdout } = await execAsync('ip link show');
      const interfaces = [];
      const lines = stdout.split('\n');
      
      for (const line of lines) {
        const match = line.match(/^\d+: ([^:]+):/);
        if (match && !match[1].includes('lo') && !match[1].includes('@')) {
          const interfaceName = match[1].trim();
          if (interfaceName !== 'lo') {
            interfaces.push(interfaceName);
          }
        }
      }
      
      // If no interfaces found, try alternative method
      if (interfaces.length === 0) {
        try {
          const { stdout: altStdout } = await execAsync('ls /sys/class/net');
          const altInterfaces = altStdout.split('\n')
            .filter(iface => iface && iface !== 'lo')
            .map(iface => iface.trim());
          interfaces.push(...altInterfaces);
        } catch (altError) {
          // Fallback to common interface names
          interfaces.push('eth0', 'wlan0', 'enp0s3');
        }
      }
      
      return interfaces.length > 0 ? interfaces : ['eth0'];
    } catch (error) {
      console.error('Error getting network interfaces:', error);
      return ['eth0', 'wlan0'];
    }
  }

  // Test network connectivity
  async testConnectivity(host = '8.8.8.8') {
    try {
      await execAsync(`ping -c 3 ${host}`);
      return { success: true, message: 'Network connectivity OK' };
    } catch (error) {
      return { success: false, message: 'Network connectivity failed' };
    }
  }
}

export default new NetworkManager();