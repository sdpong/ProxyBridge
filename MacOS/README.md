# ProxiRoute for macOS

ProxiRoute is a transparent proxy application for macOS that allows you to route network traffic through HTTP or SOCKS5 proxies with granular control using rules based on application, destination, and protocol.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Installation](#installation)
- [Configuration](#configuration)
  - [Proxy Settings](#proxy-settings)
  - [Proxy Rules](#proxy-rules)
  - [Exporting and Importing Rules](#exporting-and-importing-rules)
- [Usage](#usage)
  - [Command Line (CLI)](#command-line-cli)
- [Limitations](#limitations)
- [Building from Source](#building-from-source)
- [License](#license)

## Overview

ProxiRoute leverages macOS Network Extension framework to intercept and route network traffic. It provides a GUI application for configuration and uses a system extension to handle traffic routing based on user-defined rules.

<p align="center">
  <img src="../img/ProxyBridge-mac.png" alt="ProxiRoute macOS Main Interface" width="800"/>
  <br/>
  <em>ProxiRoute Main Window</em>
</p>

## Architecture


```
┌─────────────┐
│             │  (1) TCP/UDP packet
│ Application │       ↓
│             │
└─────────────┘
       │
       │
[user mode]───────────────────────────────────────────────────────────────────────
       │
       │  (2) Packet intercepted via Network Extension
       ↓
┌──────────────────────┐
│                      │
│   ProxiRoute        │
│   Extension          │
│   (System Extension) │
│                      │
└──────────────────────┘
       │
       │  (3) Rule matching
       ↓
   ┌───────────────────────────────────────┐
   │                                       │
   │  Match rules:                         │
   │  - Package name (bundle ID)           │
   │  - Destination IP/hostname (TCP only) │
   │  - Destination port (TCP only)        │
   │  - Protocol (TCP/UDP/Both)            │
   │                                       │
   └───────────────────────────────────────┘
       │
       │
       ├──────(4a) Rule matched: PROXY────────────────────────┐
       │                                                       │
       ├──────(4b) Rule matched: DIRECT───────────────────┐   │
       │                                                   │   │
       ├──────(4c) Rule matched: BLOCK──────────┐         │   │
       │                                        │         │   │
       └──────(4d) No rule matched─────────┐   │         │   │
                                           │   │         │   │
                                           ↓   ↓         ↓   ↓
                                       ┌────────────────────────────┐
                                       │  ProxiRoute Network       │
                                       │  Manager                   │
                                       │  (4e) Store original       │
                                       │       dest IP/port         │
                                       │  (4f) Log connection       │
                                       └────────────────────────────┘
                                                     │
                       ┌─────────────────────────────┼─────────────────────┐
                       │                             │                     │
                       │                             │                     │
           (5) BLOCK   │                 (6) DIRECT  │         (7) PROXY   │
               │       │                     │       │             │       │
               ↓       │                     ↓       │             ↓       │
          Connection   │              Pass to OS     │    ┌─────────────────────────┐
            Dropped    │              (Direct)       │    │ Extension creates       │
                       │                     │       │    │ NWTCPConnection or      │
                       │                     ↓       │    │ NWUDPSession to proxy   │
                       │              ┌────────────┐ │    └─────────────────────────┘
                       │              │ Remote     │ │              │
                       │              │ Server     │ │              │
                       │              └────────────┘ │              ↓
                       │                             │    ┌─────────────────────────┐
                       │                             │    │ Proxy Server            │
                       │                             │    │ - HTTP Proxy, or        │
                       │                             │    │ - SOCKS5 Proxy          │
                       │                             │    │                         │
                       │                             │    │ (8) Extension handles   │
                       │                             │    │     proxy handshake &   │
                       │                             │    │     data relay          │
                       │                             │    └─────────────────────────┘
                       │                             │              │
                       │                             │              ↓
                       │                             │    ┌─────────────────────────┐
                       │                             │    │ Remote Server           │
                       │                             │    │ (Final destination)     │
                       │                             │    └─────────────────────────┘
                       │                             │
                       └─────────────────────────────┴─────────────────────────────
                                         │
                                         │  (9) Response flows back through
                                         │      extension to application
                                         ↓
                                   [Application]
```

### Key Components

1. **GUI Application** (User Mode)
   - Configuration interface for proxy settings
   - Rule management (add, delete, enable/disable)
   - Connection log viewer
   - Stored in UserDefaults and shared with extension

2. **Network Extension** (System Extension)
   - Runs as a system extension
   - Intercepts all TCP/UDP traffic system-wide
   - Evaluates traffic against configured rules
   - Routes traffic based on rule actions
   - Creates NWTCPConnection for TCP proxy connections
   - Creates NWUDPSession for SOCKS5 UDP associations
   - Handles proxy protocol handshakes (HTTP CONNECT, SOCKS5)
   - Relays data between application and proxy server
   - Supports both HTTP and SOCKS5 proxies with authentication

3. **Network Manager**
   - Stores original destination details
   - Logs all connection attempts
   - Tracks active connections
   - Handles authentication when credentials provided

### Traffic Flow Details

1. **Application initiates connection** - Any application on the system makes a network request
2. **Network Extension intercepts** - ProxiRoute extension receives the connection request via NETransparentProxyProvider
3. **Rule evaluation** - Extension checks configured rules against:
   - Application bundle identifier (package name)
   - Destination IP/hostname (TCP only)
   - Destination port (TCP only)
   - Protocol (TCP/UDP/Both)
4. **Action execution**:
   - **(4a) PROXY** - Extension creates NWTCPConnection/NWUDPSession to proxy server
   - **(4b) DIRECT** - Allows direct connection bypassing proxy
   - **(4c) BLOCK** - Blocks the connection entirely
   - **(4d) No Match** - Passes to OS (Direct for TCP, logged with "unknown" for UDP)
5. **Logging** - Connection details are logged and sent to GUI
6. **Proxy handling** - For PROXY action, extension handles proxy handshake and relays data
7. **Final destination** - Traffic reaches remote server either directly or through proxy
5. **Logging** - Connection details are logged and visible in the GUI
6. **Proxy handling** - For PROXY action, establishes connection to configured proxy server
7. **Final destination** - Traffic reaches remote server either directly or through proxy

## Installation

1. Download the latest release from the [releases page](https://github.com/sdpong/ProxyBridge/releases)
2. Open the downloaded `.pkg` file
3. Follow the installation wizard
4. Grant System Extension permissions when prompted
5. Launch ProxiRoute from Applications folder

**Note:** ProxiRoute requires system extension permissions. You need to allow the extension in **System Settings → General → Login Items & Extensions → Network Extension** on first launch.


## Configuration

### The Settings Tab

The settings are in two tabs of the main window. The **Settings** tab holds
what the app does with the traffic: the running mode, the routing options and
the proxy server. The **Options** tab holds what is about the app itself: the
language, the switches of the app, the system extension and the way to the
windows that carry the rules. The two are not the same thing, and one person
who wants to change the language should not have to walk past the routes to
reach it.

<p align="center">
  <img src="../img/proxy-setting-mac.png" alt="Proxy Settings Configuration" width="600"/>
  <br/>
  <em>Proxy Settings Window</em>
</p>

#### The running mode

ProxiRoute can either take the traffic of this machine over, or wait for the
clients of the network. Both at the same time means the extension carries every
flow of this machine while the server relays the flows of the whole network,
and the processor of the machine pays for both. So the mode is **one choice**:

| Mode | What happens |
|------|--------------|
| **Local** | The traffic of this machine goes through the proxy, and the rules decide where it goes. Nothing else is done here. |
| **Gateway** | The traffic of this machine goes through the proxy, and this machine is the gateway of the network: the traffic of the other terminals goes through it. |
| **Proxy Server** | The traffic of this machine goes through the proxy, and the proxy server waits for the clients of the network. The processor of the machine pays for both. |

The **Gateway** mode is meant to be the way in for the other terminals of the
network. Today the extension only takes the traffic of this machine over - the
forwarding of the other terminals is not implemented yet, and the card says so
in orange. The name is the plan, the card tells where the plan stands.

The mode is the only switch for the proxy server: it listens when the mode is
**Proxy Server**, and it is quiet otherwise.

The **routing options** (the global mode, the outbound interface, UDP and the
local network) are the settings of the gateway: they show in the **Gateway**
mode, and the other modes use the defaults - the way the app worked before
the modes existed.

### Proxy Settings

Access proxy settings from **Options → Rule Setup → Proxy Settings**, or
from the **Window** menu of the menu bar.

#### Supported Proxy Types
- **HTTP** - Standard HTTP/HTTPS proxy
- **SOCKS5** - SOCKS5 proxy with optional UDP support

#### Configuration Fields

| Field | Description | Required | Format |
|-------|-------------|----------|--------|
| Proxy Type | Select HTTP or SOCKS5 | Yes | Dropdown selection |
| Proxy Host | Proxy server IP address, hostname, or domain | Yes | IPv4, IPv6, or domain name |
| Proxy Port | Proxy server port number | Yes | 1-65535 |
| Username | Proxy authentication username | No | Text |
| Password | Proxy authentication password | No | Text |

#### Examples

**HTTP Proxy**
```
Type: HTTP
Host: proxy.example.com
Port: 8080
Username: myuser
Password: mypass
```

**SOCKS5 Proxy**
```
Type: SOCKS5
Host: 127.0.0.1
Port: 1080
Username: (optional)
Password: (optional)
```

### Proxy Rules

Access proxy rules from **Options → Rule Setup → Proxy Rules**, or from the
**Window** menu of the menu bar.

<p align="center">
  <img src="../img/proxy-rule-mac.png" alt="Proxy Rules Management" width="800"/>
  <br/>
  <em>Proxy Rules Window</em>
</p>

Rules determine how network traffic is handled. Multiple rules can be created, and they are evaluated in order until a match is found.

#### Rule Components

| Component | Description | Supports TCP | Supports UDP |
|-----------|-------------|--------------|--------------|
| Package Name | Application bundle identifier | Yes | Yes |
| IP/Hostname | Destination IP address or domain | Yes | No* |
| Port | Destination port number | Yes | No* |
| Protocol | TCP, UDP, or Both | Yes | Yes |
| Action | PROXY, DIRECT, or BLOCK | Yes | Yes |

**Note:** UDP rules only match on package name due to Apple API limitations. IP and port-based filtering is not available for UDP traffic.

#### Actions

- **PROXY** - Route traffic through the configured proxy server
- **DIRECT** - Allow direct connection bypassing the proxy
- **BLOCK** - Block the connection entirely

#### Rule Management

- **Add Rule** - Create a new rule with specified criteria
- **Enable/Disable** - Toggle rules on/off without deleting them
- **Delete** - Remove rules permanently
- **List All** - View all configured rules and their status

<p align="center">
  <img src="../img/proxy-rule2-mac.png" alt="Add/Edit Proxy Rule" width="600"/>
  <br/>
  <em>Add/Edit Rule Window</em>
</p>

#### Rule Examples

**Block all traffic from specific app**
```
Package Name: com.example.app
IP/Hostname: (empty)
Port: (empty)
Protocol: Both
Action: BLOCK
```

**Route browser through proxy**
```
Package Name: com.google.Chrome
IP/Hostname: (empty)
Port: (empty)
Protocol: TCP
Action: PROXY
```

**Direct connection for specific domain**
```
Package Name: (empty)
IP/Hostname: trusted.example.com
Port: 443
Protocol: TCP
Action: DIRECT
```

**UDP traffic from specific app through SOCKS5**
```
Package Name: com.example.voipapp
IP/Hostname: (ignored for UDP)
Port: (ignored for UDP)
Protocol: UDP
Action: PROXY
```

#### Exporting and Importing Rules

ProxiRoute allows you to export selected rules to a JSON file and import rules from previously exported files.

**Export Rules:**
1. Select one or more rules using the checkboxes
2. Click the **Select All** button to select all rules (optional)
3. Click the **Export** button
4. Choose a location and save the JSON file

**Import Rules:**
1. Click the **Import** button
2. Select a previously exported JSON file
3. Rules will be imported and added to your existing rules

**JSON Format Example:**
```json
[
  {
    "action" : "DIRECT",
    "enabled" : true,
    "processNames" : "curl",
    "protocol" : "BOTH",
    "targetHosts" : "*",
    "targetPorts" : "*"
  }
]
```

## Usage

### Starting ProxiRoute

1. Launch ProxiRoute from Applications
2. The app runs in the menu bar
3. Pick the running mode in the **Settings** tab of the main window
4. Configure proxy settings and rules as needed
5. Enable the system extension when prompted
6. Traffic will be routed according to your rules

### Viewing Logs

Connection logs are available in the main window, showing:
- Protocol (TCP/UDP)
- Application package name
- Destination IP/hostname
- Destination port
- Action taken (PROXY/DIRECT/BLOCK)

### The Menu Bar

The menu bar of the app keeps what belongs to the documents and the help:

- **ProxiRoute** - settings, hide, quit
- **Profile** - the profiles, new, rename, delete, export, import
- **Window** - open ProxiRoute, enter full screen, and the windows of the app
- **Help** - documentation, check for updates

There is no **Edit** menu and no **View** menu. The editing keys (**⌘C**,
**⌘X**, **⌘V**, **⌘A**, **⌘Z**) keep working: they are answered by the field or
the text view that holds the keyboard, so the log can still be copied out of
it.

The two menus are hidden and not taken out of the menu bar. SwiftUI watches
the menu bar and answers a change of it by building it again - with its own
**View** menu in it. A hidden menu item is not a change of the menu bar, so
it stays hidden.

The items that macOS puts into the **Window** menu (close, minimize, zoom,
fill, center, move and resize, full screen tile) are renamed into the
language of the app, and the grey items about tabs and window sets are
taken out - this app has one window and no row of tabs.

Everything else is in the **Settings** tab and the **Options** tab of the main
window. The shortcut **⌘,** opens the settings.

The row of tabs says what the app is doing right now, at its right end: the
mode, and what it is doing in it - for example **Gateway · Proxied**. The
traffic of this machine is taken over in every mode, so the card of the running
mode has no row for it: a row that says the same thing under every option is
noise.

An empty table in the **Statistics** or the **Live Connections** tab says why
it is empty: the traffic of this machine is taken over in every mode, so the
table is empty because no traffic has gone through yet.

### Menu Bar Controls

The item in the menu bar on the right side of the screen opens:

- **Open ProxiRoute** - bring the main window back
- **Settings...** - open the main window on the settings tab
- A line that says what the app is doing right now
- **Keep Proxy Running in Background** - whether closing the window stops the proxy
- **Quit** - Exit ProxiRoute

### Command Line (CLI)

ProxiRoute can run without a window, like the Windows CLI. There is **no second program**: the CLI is the same executable as the app, started with command line options. Started normally (Finder, Dock) it is the app.

The installer adds a short command, `proxybridge`, so it works from any folder in Terminal:

```bash
proxybridge --list-profiles                     # profiles saved in the app (* = the one the app uses)
proxybridge --profile Default --verbose 2       # run a saved profile, show connections
cat ~/work.pbprofile | proxybridge --profile - --verbose 3   # run a profile exported from the app
proxybridge --update                            # check for updates
proxybridge --version
```

If the command is not found, run the executable directly (it needs no setup): `/Applications/ProxiRoute.app/Contents/MacOS/ProxiRoute --cli --help`.

| Option | |
|--------|---|
| `--profile <name>` | Run a profile saved in the app |
| `--profile -` | Read a profile (`.pbprofile` exported from the app) from standard input |
| `--list-profiles` | List the saved profiles and exit |
| `--verbose <0-3>` | 0 silent (default), 1 log messages, 2 connections, 3 both |
| `--update` | Check for updates |
| `--version`, `-h` / `--help` | Show the version / the help |

It runs in the foreground until you press **Ctrl+C**, which clears the rules and stops the tunnel.

**Things to know**
- **The extension has to be approved once.** The first run asks macOS to activate the system extension and to allow the network configuration, and **waits** until you approve them in *System Settings > Privacy & Security*. After that (or on a Mac where your administrator pre-approved them) it starts without any prompt, and it shares the approval with the app. It cannot be approved over SSH on a Mac nobody has set up yet, the prompt appears on the Mac's screen.
- **Quit the app first.** Only one of the app and the CLI can control the extension at a time, so the CLI refuses to start while the app is running.
- **Profiles are read by name or from standard input**, because the app is sandboxed and can't open arbitrary file paths. A profile exported on Windows uses a different layout and can't be loaded here.
- The app must be installed in `/Applications` (macOS only activates the extension from there). The installer package creates the `proxybridge` command; it is a three-line launcher in `/usr/local/bin`, not another binary.

## Limitations

### Apple Network Extension API Constraints

1. **Package Name vs Process Name**
   - Rules use application bundle identifier (package name), not process name
   - Apple's Network Extension API does not provide access to process names
   - Use `com.example.app` format instead of executable names

2. **UDP Traffic Limitations**
   - UDP rules can only match on package name
   - Destination IP and port are not available for UDP traffic when not handled by the extension
   - This is an Apple API limitation in the Network Extension framework
   - UDP traffic that doesn't match a rule is passed to the OS directly and logged with "unknown" IP/port

3. **System Traffic**
   - Some system processes may bypass the extension
   - Critical macOS services are not intercepted for system stability

### Protocol Support

- **TCP** - Full support with all rule matching criteria
- **UDP** - Limited to package name matching only
- **SOCKS5 UDP** - Supported when rules match and proxy through SOCKS5

## Building from Source

### Requirements

- macOS 13.0 or later
- Xcode 14.0 or later
- Swift 5.7 or later
- Valid Apple Developer account for code signing

### Build Steps

1. Clone the repository:
   ```bash
   git clone https://github.com/sdpong/ProxyBridge.git
   cd ProxiRoute/MacOS/ProxiRoute
   ```

2. Open the project:
   ```bash
   open ProxiRoute.xcodeproj
   ```

3. Configure code signing in Xcode:
   - Select the ProxiRoute target
   - Go to Signing & Capabilities
   - Select your development team

4. Build the project:
   ```bash
   xcodebuild -project ProxiRoute.xcodeproj -scheme ProxiRoute -configuration Release build
   ```

5. The built application will be in:
   ```
   ~/Library/Developer/Xcode/DerivedData/ProxiRoute-*/Build/Products/Release/ProxiRoute.app
   ```

### Creating an Installer

To create a `.pkg` installer, additional packaging steps are required using `pkgbuild` or a similar tool. See the [packaging documentation](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases) for details.

## License

See the [LICENSE](../LICENSE) file for details.

---

