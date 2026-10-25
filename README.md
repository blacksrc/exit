# exit

Route your internet traffic through another computer with [Tailscale](https://tailscale.com). Works on macOS and Linux.

The **exit node** is the computer that shares its internet. It joins your Tailscale account with a key you send it, so nobody signs in to your account there.

## 1. Both computers: install

Install [Tailscale](https://tailscale.com/download). On a Mac, open the app once and allow what it asks for.
Only you sign in: the exit node joins with the key from step 2.

Then get the script:

```sh
curl -fsSLO https://raw.githubusercontent.com/blacksrc/exit/main/exit-node.sh
chmod +x exit-node.sh
```

## 2. You: create a key

Open [Keys](https://login.tailscale.com/admin/settings/keys) - **Generate auth key**, and send the key to the exit node.

## 3. Exit node: share its internet

```sh
./exit-node.sh share tskey-auth-XXXX   # the key you were sent
```

## 4. You: approve it, once

In [Machines](https://login.tailscale.com/admin/machines), open the exit node's **⋯** menu:

- **Edit route settings** - **Use as exit node**
- **Disable key expiry**, so it keeps working after 180 days

## 5. You: route your traffic

```sh
./exit-node.sh on       # pick the exit node, all traffic now goes through it
./exit-node.sh status   # check your public IP
./exit-node.sh off      # back to normal
```

To stop sharing, run `./exit-node.sh unshare` on the exit node.
