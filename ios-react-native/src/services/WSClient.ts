import {NativeModules, NativeEventEmitter} from 'react-native';

const {WebSocketModule} = NativeModules;
const eventEmitter = new NativeEventEmitter(WebSocketModule);

class WSClient {
  private static instance: WSClient;
  private isConnectedValue: boolean = false;

  onConnectionStateChanged?: (connected: boolean) => void;
  onControlMessage?: (action: string) => void;
  onRoomUpdate?: (data: any) => void;
  onInstruction?: (message: string) => void;
  onStatus?: (message: string) => void;

  private constructor() {
    // Set up event listeners
    eventEmitter.addListener('connectionStateChanged', (connected: boolean) => {
      this.isConnectedValue = connected;
      this.onConnectionStateChanged?.(connected);
    });

    eventEmitter.addListener('controlMessage', (action: string) => {
      this.onControlMessage?.(action);
    });

    eventEmitter.addListener('roomUpdate', (data: any) => {
      this.onRoomUpdate?.(data);
    });

    eventEmitter.addListener('instruction', (message: string) => {
      this.onInstruction?.(message);
    });

    eventEmitter.addListener('status', (message: string) => {
      this.onStatus?.(message);
    });
  }

  static get shared(): WSClient {
    if (!WSClient.instance) {
      WSClient.instance = new WSClient();
    }
    return WSClient.instance;
  }

  get isConnected(): boolean {
    return this.isConnectedValue;
  }

  async connect(laptopIP: string, token: string): Promise<boolean> {
    try {
      const result = await WebSocketModule.connect(laptopIP, token);
      this.isConnectedValue = result;
      return result;
    } catch (error) {
      console.error('WebSocket connection error:', error);
      return false;
    }
  }

  disconnect(): void {
    WebSocketModule.disconnect();
    this.isConnectedValue = false;
  }

  sendMessage(message: string): void {
    if (this.isConnectedValue) {
      WebSocketModule.sendMessage(message);
    }
  }
}

export default WSClient;
