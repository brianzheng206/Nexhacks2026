import {NativeModules} from 'react-native';

const {QRCodeScannerModule: NativeQRScanner} = NativeModules;

interface QRCodeScannerModuleInterface {
  scan(): Promise<{token: string | null; host: string | null}>;
}

const QRCodeScannerModule = NativeQRScanner as QRCodeScannerModuleInterface;

export default QRCodeScannerModule;
export {QRCodeScannerModule};
