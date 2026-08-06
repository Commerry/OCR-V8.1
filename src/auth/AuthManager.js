import fs from "fs-extra";
import path from "path";

class AuthManager {
  constructor() {
    this.usersFilePath = path.join(process.cwd(), "config", "users.json");
    this.sessions = new Map();
    this.loginAttempts = new Map();
  }

  // Load users from config file
  loadUsers() {
    try {
      console.log('[AuthManager] Loading users from:', this.usersFilePath);
      if (!fs.existsSync(this.usersFilePath)) {
        console.warn('[AuthManager] users.json not found, creating default at:', this.usersFilePath);
        // Create default users file if not exists
        const defaultConfig = {
          users: [
            {
              username: "STA-SK",
              password: "Abc123**",
              role: "user",
              created: new Date().toISOString(),
              lastLogin: null,
              active: true,
            },
            {
              username: "Admin",
              password: "Abc123**",
              role: "admin",
              created: new Date().toISOString(),
              lastLogin: null,
              active: true,
            },
          ],
          settings: {
            sessionTimeout: 86400,
            maxLoginAttempts: 5,
            lockoutDuration: 1800,
          },
        };
        // config/ is not in the repo (users.json is gitignored) - create it
        fs.mkdirSync(path.dirname(this.usersFilePath), { recursive: true });
        fs.writeFileSync(
          this.usersFilePath,
          JSON.stringify(defaultConfig, null, 2)
        );
      }

      const data = fs.readFileSync(this.usersFilePath, "utf8");
      const parsed = JSON.parse(data);
      console.log('[AuthManager] Loaded', parsed.users?.length || 0, 'users');
      return parsed;
    } catch (error) {
      console.error("[AuthManager] Error loading users:", error);
      return { users: [], settings: {} };
    }
  }

  // Save users to config file
  saveUsers(config) {
    try {
      fs.writeFileSync(this.usersFilePath, JSON.stringify(config, null, 2));
      return true;
    } catch (error) {
      console.error("Error saving users:", error);
      return false;
    }
  }

  // Authenticate user
  authenticate(username, password) {
    const config = this.loadUsers();
    console.log('[AuthManager] authenticate:', username, '| users in config:', config.users.length);
    const user = config.users.find(
      (u) => u.username === username && u.password === password && u.active
    );

    if (user) {
      // Update last login
      user.lastLogin = new Date().toISOString();
      this.saveUsers(config);

      // Clear login attempts
      this.loginAttempts.delete(username);

      return {
        success: true,
        user: {
          username: user.username,
          role: user.role,
          lastLogin: user.lastLogin,
        },
      };
    }

    // Track failed login attempts
    const attempts = this.loginAttempts.get(username) || 0;
    this.loginAttempts.set(username, attempts + 1);

    return {
      success: false,
      message: "Invalid credentials",
      attempts: attempts + 1,
    };
  }

  // Create session
  createSession(user) {
    const sessionId =
      Math.random().toString(36).substring(2) + Date.now().toString(36);
    const session = {
      ...user,
      loginTime: new Date(),
      lastActivity: new Date(),
    };

    this.sessions.set(sessionId, session);
    return sessionId;
  }

  // Validate session
  validateSession(sessionId) {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return null;
    }

    // Update last activity
    session.lastActivity = new Date();
    this.sessions.set(sessionId, session);

    return session;
  }

  // Remove session
  removeSession(sessionId) {
    return this.sessions.delete(sessionId);
  }

  // Get user by username
  getUser(username) {
    const config = this.loadUsers();
    return config.users.find((u) => u.username === username);
  }

  // Add new user
  addUser(userData) {
    const config = this.loadUsers();

    // Check if user already exists
    if (config.users.find((u) => u.username === userData.username)) {
      return { success: false, message: "User already exists" };
    }

    const newUser = {
      username: userData.username,
      password: userData.password,
      role: userData.role || "user",
      created: new Date().toISOString(),
      lastLogin: null,
      active: true,
    };

    config.users.push(newUser);

    if (this.saveUsers(config)) {
      return { success: true, user: newUser };
    }

    return { success: false, message: "Failed to save user" };
  }

  // Update user
  updateUser(username, updateData) {
    const config = this.loadUsers();
    const userIndex = config.users.findIndex((u) => u.username === username);

    if (userIndex === -1) {
      return { success: false, message: "User not found" };
    }

    // Update user data
    config.users[userIndex] = {
      ...config.users[userIndex],
      ...updateData,
      updated: new Date().toISOString(),
    };

    if (this.saveUsers(config)) {
      return { success: true, user: config.users[userIndex] };
    }

    return { success: false, message: "Failed to update user" };
  }

  // Delete user
  deleteUser(username) {
    const config = this.loadUsers();
    const userIndex = config.users.findIndex((u) => u.username === username);

    if (userIndex === -1) {
      return { success: false, message: "User not found" };
    }

    config.users.splice(userIndex, 1);

    if (this.saveUsers(config)) {
      return { success: true, message: "User deleted" };
    }

    return { success: false, message: "Failed to delete user" };
  }

  // List all users
  listUsers() {
    const config = this.loadUsers();
    return config.users.map((user) => ({
      username: user.username,
      role: user.role,
      created: user.created,
      lastLogin: user.lastLogin,
      active: user.active,
    }));
  }

  // Clean expired sessions
  cleanExpiredSessions() {
    const config = this.loadUsers();
    const timeout = (config.settings.sessionTimeout || 86400) * 1000; // Convert to milliseconds
    const now = Date.now();

    for (const [sessionId, session] of this.sessions.entries()) {
      if (now - session.lastActivity.getTime() > timeout) {
        this.sessions.delete(sessionId);
      }
    }
  }
}

export default new AuthManager();
