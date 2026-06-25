#include <Arduino.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define MPU_ADDR            0x68
#define SERVICE_UUID        "4FAFC201-1FB5-459E-8FCC-C5C9C331914B"
#define CHARACTERISTIC_UUID "BEB5483E-36E1-4688-B7F5-EA07361B26A8"

BLECharacteristic *pCharacteristic;
bool deviceConnected = false;

// --- UPGRADED: Expanded structure to hold 12 bytes (6 Accel + 6 Gyro) ---
struct ArcheryData {
    uint8_t buffer[12];
};

// Create a FreeRTOS Queue handle
QueueHandle_t dataQueue;

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) { deviceConnected = true; };
    void onDisconnect(BLEServer* pServer) { deviceConnected = false; }
};

// Task Handlers
void TaskReadSensor(void *pvParameters);
void TaskSendBLE(void *pvParameters);

void setup() {
  Serial.begin(115200);
  
  Wire.begin(21, 22);
  Wire.setClock(400000); // 400kHz Fast Mode I2C

  delay(1000);
  
  // --- MANUAL MPU6050 WAKEUP ---
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B); // Power Management 1 register address
  Wire.write(0);    // Setting to 0 wakes up the MPU-6050
  byte error = Wire.endTransmission();

  if (error == 0) {
    //Serial.println("MPU6050 hardware responding directly! Forced initialization successful.");
  } else {
    //Serial.print("Hardware communication failed with I2C Error code: ");
    //Serial.println(error);
    
  }

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1B); 
  Wire.write(0x08);
  Wire.endTransmission();

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1C);
  Wire.write(0x08); 
  Wire.endTransmission();


  BLEDevice::init("Guacamole-Archery");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();
  pServer->getAdvertising()->start();

  dataQueue = xQueueCreate(10, sizeof(ArcheryData));

  if (dataQueue != NULL) {
    xTaskCreatePinnedToCore(
      TaskReadSensor,    
      "ReadSensor",      
      4096,             
      NULL,              
      2,                 
      NULL,              
      0                  
    );

    xTaskCreatePinnedToCore(
      TaskSendBLE,
      "SendBLE",
      4096,
      NULL,
      1,                
      NULL,
      1                  
    );
  }
}

void TaskReadSensor(void *pvParameters) {
  TickType_t xLastWakeTime = xTaskGetTickCount();
  const TickType_t xDelay5ms = pdMS_TO_TICKS(5);

  for(;;) {
    Wire.beginTransmission(MPU_ADDR);
    Wire.write(0x3B); 
    Wire.endTransmission(false);
    
    Wire.requestFrom(MPU_ADDR, 14, true);

    ArcheryData currentSample;
    
    if (Wire.available() == 14) {
      currentSample.buffer[0] = Wire.read(); // Accel X High Byte
      currentSample.buffer[1] = Wire.read(); // Accel X Low Byte
      currentSample.buffer[2] = Wire.read(); // Accel Y High Byte
      currentSample.buffer[3] = Wire.read(); // Accel Y Low Byte
      currentSample.buffer[4] = Wire.read(); // Accel Z High Byte
      currentSample.buffer[5] = Wire.read(); // Accel Z Low Byte
      uint8_t tempHigh = Wire.read();
      uint8_t tempLow  = Wire.read();
      currentSample.buffer[6] = Wire.read(); // Gyro X High Byte
      currentSample.buffer[7] = Wire.read(); // Gyro X Low Byte
      currentSample.buffer[8] = Wire.read(); // Gyro Y High Byte
      currentSample.buffer[9] = Wire.read(); // Gyro Y Low Byte
      currentSample.buffer[10] = Wire.read(); // Gyro Z High Byte
      currentSample.buffer[11] = Wire.read(); // Gyro Z Low Byte

      double accelX = (curentSample.buffer[6] << 8) | currentSample.buffer[7];
      double accelY = (currentSample.buffer[8] << 8) | currentSample.buffer[9];
      double accelZ = (currentSample.buffer[10] << 8) | currentSample.buffer[11];

      Serial.println(sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ));
      xQueueSend(dataQueue, &currentSample, 0);
    }

    // Pause accurately until exactly 5ms has elapsed since last read
    vTaskDelayUntil(&xLastWakeTime, xDelay5ms);
  }
}

// CORE 1: Pops 12-byte packets off the queue and streams them out via Bluetooth
void TaskSendBLE(void *pvParameters) {
  ArcheryData receivedSample;

  for(;;) {
    if (xQueueReceive(dataQueue, &receivedSample, portMAX_DELAY)) {
      if (deviceConnected) {
        // --- UPGRADED: Broadcast all 12 bytes down the BLE stream pipe ---
        pCharacteristic->setValue(receivedSample.buffer, 12);
        pCharacteristic->notify();
      }
    }
  }
}

void loop() {
  vTaskDelete(NULL); 
}
