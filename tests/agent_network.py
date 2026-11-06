"""Exercise the real host firewall with disposable guest and uplink namespaces."""

import json
import subprocess
import time


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def ip(*args):
    return run("ip", *args)


server = r"""
import selectors, socket, sys
s = selectors.DefaultSelector()
for port in (22, 53, 80, 443, 2222, 7297, 8080):
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', port)); sock.listen(); s.register(sock, 1)
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(('0.0.0.0', 53)); s.register(udp, 1)
print('ready', flush=True)
while True:
    for key, _ in s.select():
        if key.fileobj == udp:
            data, addr = udp.recvfrom(1024); udp.sendto(data, addr)
        else:
            conn, addr = key.fileobj.accept(); conn.sendall(b'OK'); conn.close()
"""
probe = r"""
import socket, sys
family = socket.AF_INET6 if ':' in sys.argv[1] else socket.AF_INET
s = socket.socket(family, socket.SOCK_STREAM); s.settimeout(0.5)
if len(sys.argv) > 3: s.bind((sys.argv[3], 0))
s.connect((sys.argv[1], int(sys.argv[2])))
assert s.recv(2) == b'OK'
print(s.getsockname())
"""


def check(address, port, *, allowed, namespace="guest", source=None):
    command = [
        "ip",
        "netns",
        "exec",
        namespace,
        "python3",
        "-c",
        probe,
        address,
        str(port),
    ]
    if source:
        command.append(source)
    result = subprocess.run(command, capture_output=True, text=True)
    assert (result.returncode == 0) == allowed, (
        address,
        port,
        source,
        allowed,
        result.stderr,
        result.stdout,
        run("nft", "list", "table", "inet", "agent_boundary"),
    )
    print(
        f"{'allowed' if allowed else 'blocked'} {source or namespace} -> {address}:{port}",
        flush=True,
    )


for ns, host_if, guest_if, host_ip, peer_ip in (
    ("guest", "agenttap0", "eth0", "10.200.201.1/30", "10.200.201.2/30"),
    ("uplink", "uplink0", "eth0", "10.0.1.10/24", "10.0.1.20/24"),
):
    ip("netns", "add", ns)
    ip("link", "add", host_if, "type", "veth", "peer", "name", "peer0")
    ip("link", "set", "peer0", "netns", ns)
    ip("-n", ns, "link", "set", "peer0", "name", guest_if)
    ip("addr", "add", host_ip, "dev", host_if)
    ip("link", "set", host_if, "up")
    ip("-n", ns, "addr", "add", peer_ip, "dev", guest_if)
    ip("-n", ns, "link", "set", guest_if, "up")
    ip("-n", ns, "link", "set", "lo", "up")
    ip("-n", ns, "route", "add", "default", "via", host_ip.split("/")[0])
ip("-n", "uplink", "addr", "add", "1.1.1.1/32", "dev", "eth0")
ip("-n", "uplink", "addr", "add", "10.0.1.11/32", "dev", "eth0")
ip("route", "add", "1.1.1.1/32", "via", "10.0.1.20")
# Simulate an unrelated Docker/service accepting every forwarded connection.
run("iptables", "-I", "FORWARD", "1", "-j", "ACCEPT")
processes = []
try:
    for ns in (None, "guest", "uplink"):
        prefix = ["ip", "netns", "exec", ns] if ns else []
        p = subprocess.Popen(
            prefix + ["python3", "-c", server], stdout=subprocess.PIPE, text=True
        )
        processes.append(p)
        assert p.stdout.readline().strip() == "ready"
    for port in (443, 2222):
        check("10.0.1.10", port, allowed=True)
    for port in (22, 7297, 8080):
        check("10.0.1.10", port, allowed=False)
    check("10.200.201.1", 443, allowed=False)
    for port in (22, 443, 7297):
        check("10.0.1.11", port, allowed=False)
    check("10.0.1.20", 53, allowed=True)
    run(
        "ip",
        "netns",
        "exec",
        "guest",
        "python3",
        "-c",
        "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); "
        "s.sendto(b'dns',('10.0.1.20',53)); assert s.recv(32)==b'dns'",
    )
    check("10.0.1.20", 443, allowed=False)
    for port in (80, 443):
        check("1.1.1.1", port, allowed=True)
    check("1.1.1.1", 22, allowed=False)
    check("10.200.201.2", 22, allowed=False, namespace="uplink")
    # Spoofing a different source cannot escape the interface-scoped guard.
    ip("-n", "guest", "addr", "add", "10.200.201.9/32", "dev", "eth0")
    ip("route", "add", "10.200.201.9/32", "dev", "agenttap0")
    check("1.1.1.1", 443, allowed=False, source="10.200.201.9")
    ip("-n", "guest", "addr", "add", "fd00::2/64", "dev", "eth0")
    ip("addr", "add", "fd00::1/64", "dev", "agenttap0")
    time.sleep(2)
    # Even an IPv6 listener on the host cannot be reached.
    v6 = subprocess.Popen(
        [
            "python3",
            "-c",
            "import socket; s=socket.socket(socket.AF_INET6); s.bind(('fd00::1',443)); "
            "s.listen(); print('ready',flush=True); c,a=s.accept(); c.sendall(b'OK')",
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    processes.append(v6)
    assert v6.stdout.readline().strip() == "ready"
    check("fd00::1", 443, allowed=False)
    # A public address DNATed by another service must not bypass private denies.
    run(
        "iptables",
        "-t",
        "nat",
        "-I",
        "PREROUTING",
        "-i",
        "agenttap0",
        "-d",
        "1.1.1.2",
        "-p",
        "tcp",
        "--dport",
        "443",
        "-j",
        "DNAT",
        "--to-destination",
        "10.0.1.11:443",
    )
    check("1.1.1.2", 443, allowed=False)
    # Stop leaves the boundary in place; start/reload replaces it atomically.
    run("systemctl", "stop", "agent-boundary")
    check("10.0.1.10", 22, allowed=False)
    run("systemctl", "start", "agent-boundary")
    run("systemctl", "reload", "agent-boundary")
    check("1.1.1.1", 443, allowed=True)
    check("10.0.1.11", 443, allowed=False)
    rules = json.loads(run("nft", "--json", "list", "table", "inet", "agent_boundary"))
    assert rules["nftables"]
finally:
    for p in processes:
        p.terminate()
    for p in processes:
        p.wait(timeout=5)
print("Network boundary checks passed.")
