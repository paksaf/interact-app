// SPDX-License-Identifier: AGPL-3.0
//
// InteractTalk LoRa ↔ BLE bridge (DIY ESP32 + RA-02 / SX127x).
// Phone writes UTF-8 to BLE RX → LoRa TX; LoRa RX → BLE notify TX.
// Prefer Meshtastic hardware for production trials; this sketch is the
// minimal custom path documented in docs/OFFLINE_MESH_LORA_BRIDGE_*.md

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <SPI.h>
#include <LoRa.h>

// ── Regional RF ──────────────────────────────────────────────────────
// Pakistan / many Americas: 915E6. EU: 868E6. Match both bridges.
#ifndef LORA_FREQ
#define LORA_FREQ 915E6
#endif

// ── RA-02 ↔ ESP32 (adjust to your wiring) ────────────────────────────
#define LORA_SS   5
#define LORA_RST  14
#define LORA_DIO0 2

// ── BLE UUIDs (Talk bridge GATT) ─────────────────────────────────────
#define SERVICE_UUID        "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define CHAR_TX_UUID        "6e400003-b5a3-f393-e0a9-e50e24dcca9e" // notify → phone
#define CHAR_RX_UUID        "6e400002-b5a3-f393-e0a9-e50e24dcca9e" // write ← phone

BLECharacteristic *pTxCharacteristic = nullptr;
bool deviceConnected = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { deviceConnected = true; }
  void onDisconnect(BLEServer *server) override {
    deviceConnected = false;
    server->startAdvertising();
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    std::string value = characteristic->getValue();
    if (value.empty()) return;
    // Cap payload for LoRa airtime / regulatory comfort.
    if (value.size() > 200) value.resize(200);
    LoRa.beginPacket();
    LoRa.write(reinterpret_cast<const uint8_t *>(value.data()), value.size());
    LoRa.endPacket();
  }
};

void setup() {
  Serial.begin(115200);
  delay(200);

  LoRa.setPins(LORA_SS, LORA_RST, LORA_DIO0);
  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println("LoRa init failed — check wiring/frequency");
    while (true) delay(1000);
  }
  LoRa.setTxPower(17);
  Serial.println("LoRa up");

  BLEDevice::init("InteractLoRaBridge");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);
  pTxCharacteristic = pService->createCharacteristic(
      CHAR_TX_UUID,
      BLECharacteristic::PROPERTY_NOTIFY);
  pTxCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
      CHAR_RX_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  pRxCharacteristic->setCallbacks(new RxCallbacks());

  pService->start();
  pServer->getAdvertising()->start();
  Serial.println("BLE advertising InteractLoRaBridge");
}

void loop() {
  const int packetSize = LoRa.parsePacket();
  if (packetSize > 0 && deviceConnected && pTxCharacteristic != nullptr) {
    String message;
    message.reserve(packetSize);
    while (LoRa.available()) {
      message += static_cast<char>(LoRa.read());
    }
    if (message.length() > 0) {
      pTxCharacteristic->setValue(message.c_str());
      pTxCharacteristic->notify();
    }
  }
  delay(5);
}
