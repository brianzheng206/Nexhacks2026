import {NativeModules, NativeEventEmitter} from 'react-native';

const {RoomPlanModule: NativeRoomPlan} = NativeModules;
const eventEmitter = new NativeEventEmitter(NativeRoomPlan);

interface RoomPlanModuleInterface {
  isSupported(): Promise<boolean>;
  startScan(token: string): Promise<void>;
  stopScan(): Promise<void>;
  setLaptopIP(laptopIP: string): void;
  addListener(eventType: string, listener: (data: any) => void): any;
  removeAllListeners(eventType: string): void;
}

class RoomPlanModuleImpl implements RoomPlanModuleInterface {
  async isSupported(): Promise<boolean> {
    return NativeRoomPlan.isSupported();
  }

  async startScan(token: string): Promise<void> {
    return NativeRoomPlan.startScan(token);
  }

  async stopScan(): Promise<void> {
    return NativeRoomPlan.stopScan();
  }

  setLaptopIP(laptopIP: string): void {
    if (NativeRoomPlan.setLaptopIP) {
      NativeRoomPlan.setLaptopIP(laptopIP);
    }
  }

  // Listen for scan events
  addListener(eventType: string, listener: (data: any) => void) {
    return eventEmitter.addListener(eventType, listener);
  }

  removeAllListeners(eventType: string) {
    eventEmitter.removeAllListeners(eventType);
  }
}

export const RoomPlanModule = new RoomPlanModuleImpl() as RoomPlanModuleInterface;
