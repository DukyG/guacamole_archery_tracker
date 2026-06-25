#include <Arduino.h>
#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define MPU_ADDR            0x68
#define MPU_INT_PIN         23      // Connect MPU6050 'INT' pin to GPIO 23
#define SERVICE_UUID        "4FAFC201-1FB5-459E-8FCC-C5C9C331914B"
#define CHARACTERISTIC_UUID "BEB5483E-36E1-4688-B7F5-EA07361B26A8"

BLECharacteristic *pCharacteristic;
bool deviceConnected = false;

struct ArcheryData {
    uint8_t buffer[13]; 
};

QueueHandle_t dataQueue;
volatile bool clickerDetected = false;
volatile uint32_t clickerTimestamp = 0;

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) { deviceConnected = true; };
    void onDisconnect(BLEServer* pServer) { deviceConnected = false; }
};

void IRAM_ATTR clickerISR() {
  clickerDetected = true;
  clickerTimestamp = millis();
}
void setMPU6050to8G() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1C);
  Wire.write(0x10);
  Wire.endTransmission();
  delay(10);
  Serial.println("[✓] MPU6050 calibrated to +/- 8G limit!");
}

void configureMPU6050Interrupt() {
  pinMode(MPU_INT_PIN, INPUT);
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3A); // INT_STATUS
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 1);
  if(Wire.available()) Wire.read(); 

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1F); // MOT_THR
  Wire.write(0x2F); 
  Wire.endTransmission();

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x20); // MOT_DUR
  Wire.write(0x01);
  Wire.endTransmission();

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x37); // INT_PIN_CFG
  Wire.write(0x00);
  Wire.endTransmission();

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x38); // INT_ENABLE
  Wire.write(0x40); 
  Wire.endTransmission();

  attachInterrupt(digitalPinToInterrupt(MPU_INT_PIN), clickerISR, RISING);
  Serial.println("[✓] Hardware Motion Detection armed at 1.5G!");
}

void TaskReadSensor(void *pvParameters);
void TaskSendBLE(void *pvParameters);

void setup() {
  Serial.begin(115200);
  
  Wire.begin(21, 22);
  Wire.setClock(400000);
  delay(500);
  
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B); 
  Wire.write(0x00);    
  Wire.endTransmission();
  delay(100);

  setMPU6050to8G();
  configureMPU6050Interrupt();

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x1B); 
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
    xTaskCreatePinnedToCore(TaskReadSensor, "ReadSensor", 4096, NULL, 2, NULL, 0);
    xTaskCreatePinnedToCore(TaskSendBLE, "SendBLE", 4096, NULL, 1, NULL, 1);
  }
}

void TaskReadSensor(void *pvParameters) {
  TickType_t xLastWakeTime = xTaskGetTickCount();
  const TickType_t xDelay5ms = pdMS_TO_TICKS(5);

  double lastRawAccel = 0.0;
  double lastFilteredAccel = 0.0;
  const double alpha = 0.90;

  for(;;) {
    Wire.beginTransmission(MPU_ADDR);
    Wire.write(0x3B); 
    Wire.endTransmission(false);
    
    Wire.requestFrom(MPU_ADDR, 14, true);
    ArcheryData currentSample;
    
    if (Wire.available() == 14) {
      currentSample.buffer[0] = Wire.read(); // Accel X High
      currentSample.buffer[1] = Wire.read(); // Accel X Low
      currentSample.buffer[2] = Wire.read(); // Accel Y High
      currentSample.buffer[3] = Wire.read(); // Accel Y Low
      currentSample.buffer[4] = Wire.read(); // Accel Z High
      currentSample.buffer[5] = Wire.read(); // Accel Z Low
      
      uint8_t tempHigh = Wire.read();
      uint8_t tempLow  = Wire.read();
      
      currentSample.buffer[6] = Wire.read(); // Gyro X High
      currentSample.buffer[7] = Wire.read(); // Gyro X Low
      currentSample.buffer[8] = Wire.read(); // Gyro Y High
      currentSample.buffer[9] = Wire.read(); // Gyro Y Low
      currentSample.buffer[10] = Wire.read(); // Gyro Z High
      currentSample.buffer[11] = Wire.read(); // Gyro Z Low

      int16_t rawX = (currentSample.buffer[0] << 8) | currentSample.buffer[1];
      int16_t rawY = (currentSample.buffer[2] << 8) | currentSample.buffer[3];
      int16_t rawZ = (currentSample.buffer[4] << 8) | currentSample.buffer[5];
      
      double currentRawAccel = sqrt((double)rawX * rawX + (double)rawY * rawY + (double)rawZ * rawZ);

      double filteredAccel = alpha * (lastFilteredAccel + currentRawAccel - lastRawAccel);
      
      lastRawAccel = currentRawAccel;
      lastFilteredAccel = filteredAccel;

      if (clickerDetected) {
        currentSample.buffer[12] = 1;
        clickerDetected = false;
      } else {
        currentSample.buffer[12] = 0;
      }
      Serial.println(filteredAccel);
      
      xQueueSend(dataQueue, &currentSample, 0);
    }

    vTaskDelayUntil(&xLastWakeTime, xDelay5ms);
  }
}

void TaskSendBLE(void *pvParameters) {
  ArcheryData receivedSample;
  for(;;) {
    if (xQueueReceive(dataQueue, &receivedSample, portMAX_DELAY)) {
      if (deviceConnected) {
        pCharacteristic->setValue(receivedSample.buffer, 13);
        pCharacteristic->notify();
      }
    }
  }
}

void loop() {
  vTaskDelete(NULL); 
}