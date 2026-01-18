import React from 'react';
import {View, Text, TouchableOpacity, StyleSheet, Modal} from 'react-native';
import {QRCodeScannerModule} from '../native/QRCodeScannerModule';

interface QRScannerProps {
  onScanned: (token: string | null, host: string | null) => void;
  onCancel: () => void;
}

const QRScanner: React.FC<QRScannerProps> = ({onScanned, onCancel}) => {
  const handleScan = async () => {
    try {
      const result = await QRCodeScannerModule.scan();
      if (result) {
        onScanned(result.token, result.host);
      }
    } catch (error) {
      console.error('QR scan error:', error);
      onCancel();
    }
  };

  React.useEffect(() => {
    handleScan();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <Modal visible={true} animationType="slide" transparent={false}>
      <View style={styles.container}>
        <Text style={styles.instruction}>Point camera at QR code</Text>
        <TouchableOpacity style={styles.cancelButton} onPress={onCancel}>
          <Text style={styles.cancelButtonText}>Cancel</Text>
        </TouchableOpacity>
      </View>
    </Modal>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
    justifyContent: 'center',
    alignItems: 'center',
  },
  instruction: {
    color: '#fff',
    fontSize: 18,
    fontWeight: '500',
    marginBottom: 40,
    backgroundColor: 'rgba(0,0,0,0.6)',
    padding: 16,
    borderRadius: 8,
  },
  cancelButton: {
    position: 'absolute',
    top: 50,
    right: 20,
    backgroundColor: 'rgba(239, 68, 68, 0.7)',
    padding: 12,
    borderRadius: 8,
    minWidth: 100,
    alignItems: 'center',
  },
  cancelButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});

export default QRScanner;
