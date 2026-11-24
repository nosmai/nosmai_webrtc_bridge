# WebRTC camera example

Publish a filtered camera from an Android phone or iPhone and watch it in a browser or on a second phone. The sender and viewer use the same signalling address and room name.

## Before you start

- Use a physical Android ARM64 device running API 24+ or an iPhone running iOS 15+. Put the phone and computer on the same local network.
- Both mobile apps use the identifier `com.nosmai.webrtcbridge.example`. Obtain a Nosmai license for this identifier on the sender platform. If using your own ID, update the Android app configuration or iOS Runner bundle ID and use its matching license.
- To run on an iPhone, select your Apple development team in the Runner target in Xcode. Allow local-network access when prompted.

## Run the example

From the bridge repository root, start the local signalling server in one terminal. It also serves the browser viewer.

```sh
cd example/server
npm ci
npm start
```

In a second terminal, from the repository root, run the Flutter app on the phone.

```sh
cd example
flutter pub get
flutter run --release
```

1. On the phone, enter the server address printed by the server, such as `ws://192.168.1.10:8080`, the room name and the sender’s Nosmai license.
2. Tap **Open sender (go live)**, grant camera and microphone access, and wait for the camera preview. Tap **Go Live**.
3. On the computer, open [the browser viewer](http://localhost:8080/viewer.html?room=qa) and select **Connect**. If you changed the room on the phone, enter the same room in the viewer. A second phone can also join with **Open viewer**.
4. Tap **Effects** on the sender and choose a visible effect. Confirm it reaches the viewer, then use **Stop Live** to end the broadcast.

In an existing app, keep your signalling service and ICE configuration. The local server is only needed for this example. [Bridge integration guide](../README.md)
