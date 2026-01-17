import React, {useState, useEffect} from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ScrollView,
} from 'react-native';
import {NativeStackScreenProps} from '@react-navigation/native-stack';
import {RootStackParamList} from '../App';
import {RoomPlanModule} from '../native/RoomPlanModule';
import WSClient from '../services/WSClient';

type Props = NativeStackScreenProps<RootStackParamList, 'Scan'>;

const ScanScreen: React.FC<Props> = ({route}) => {
  const {laptopIP, token} = route.params;
  const [status, setStatus] = useState('Connected');
  const [isScanning, setIsScanning] = useState(false);
  const [roomStats, setRoomStats] = useState<string>('No data received yet...');

  useEffect(() => {
    // Set up WebSocket handlers
    const wsClient = WSClient.shared;

    wsClient.onConnectionStateChanged = (connected: boolean) => {
      setStatus(connected ? 'Connected' : 'Disconnected');
    };

    wsClient.onControlMessage = (action: string) => {
      if (action === 'start') {
        // handleStartScan will be defined below
        // eslint-disable-next-line react-hooks/exhaustive-deps
        handleStartScan();
      } else if (action === 'stop') {
        // eslint-disable-next-line react-hooks/exhaustive-deps
        handleStopScan();
      }
    };

    wsClient.onRoomUpdate = (data: any) => {
      setRoomStats(JSON.stringify(data, null, 2));
    };

    // Check if RoomPlan is supported
    RoomPlanModule.isSupported().then((supported: boolean) => {
      if (!supported) {
        setStatus('RoomPlan not supported');
      }
    });

    return () => {
      // Cleanup
      wsClient.onConnectionStateChanged = undefined;
      wsClient.onControlMessage = undefined;
      wsClient.onRoomUpdate = undefined;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleStartScan = async () => {
    try {
      const supported = await RoomPlanModule.isSupported();
      if (!supported) {
        Alert.alert('Error', 'RoomPlan is not supported on this device');
        return;
      }

      if (!WSClient.shared.isConnected) {
        Alert.alert('Error', 'Not connected to server');
        return;
      }

      await RoomPlanModule.startScan(token);
      setIsScanning(true);
      setStatus('Scanning');
    } catch (error) {
      Alert.alert(
        'Error',
        error instanceof Error ? error.message : 'Failed to start scan',
      );
    }
  };

  const handleStopScan = async () => {
    try {
      await RoomPlanModule.stopScan();
      setIsScanning(false);
      setStatus(WSClient.shared.isConnected ? 'Connected' : 'Disconnected');
    } catch (error) {
      Alert.alert(
        'Error',
        error instanceof Error ? error.message : 'Failed to stop scan',
      );
    }
  };

  const getStatusColor = () => {
    switch (status.toLowerCase()) {
      case 'connected':
        return '#10b981';
      case 'scanning':
        return '#3b82f6';
      case 'disconnected':
        return '#ef4444';
      default:
        return '#f59e0b';
    }
  };

  return (
    <ScrollView style={styles.container}>
      <View style={styles.statusContainer}>
        <Text style={styles.statusLabel}>Status</Text>
        <View style={[styles.statusBox, {borderColor: getStatusColor()}]}>
          <Text style={[styles.statusText, {color: getStatusColor()}]}>
            {status}
          </Text>
        </View>
      </View>

      <View style={styles.buttonGroup}>
        <TouchableOpacity
          style={[
            styles.button,
            styles.startButton,
            (isScanning || !WSClient.shared.isConnected) &&
              styles.buttonDisabled,
          ]}
          onPress={handleStartScan}
          disabled={isScanning || !WSClient.shared.isConnected}>
          <Text style={styles.buttonText}>Start Scan</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[
            styles.button,
            styles.stopButton,
            !isScanning && styles.buttonDisabled,
          ]}
          onPress={handleStopScan}
          disabled={!isScanning}>
          <Text style={styles.buttonText}>Stop Scan</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.infoContainer}>
        <Text style={styles.infoLabel}>Connection Info</Text>
        <Text style={styles.infoText}>IP: {laptopIP}</Text>
        <Text style={styles.infoText}>Token: {token}</Text>
      </View>

      <View style={styles.logContainer}>
        <Text style={styles.logLabel}>Room Stats</Text>
        <Text style={styles.logContent}>{roomStats}</Text>
      </View>
    </ScrollView>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    backgroundColor: '#fff',
  },
  statusContainer: {
    marginBottom: 20,
  },
  statusLabel: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 10,
    color: '#333',
  },
  statusBox: {
    padding: 16,
    borderRadius: 10,
    borderWidth: 2,
    backgroundColor: '#f9fafb',
  },
  statusText: {
    fontSize: 16,
    fontWeight: '500',
  },
  buttonGroup: {
    marginBottom: 20,
  },
  button: {
    padding: 16,
    borderRadius: 10,
    alignItems: 'center',
    marginBottom: 10,
  },
  startButton: {
    backgroundColor: '#10b981',
  },
  stopButton: {
    backgroundColor: '#ef4444',
  },
  buttonDisabled: {
    backgroundColor: '#9ca3af',
  },
  buttonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  infoContainer: {
    backgroundColor: '#f9fafb',
    padding: 16,
    borderRadius: 10,
    marginBottom: 20,
  },
  infoLabel: {
    fontSize: 16,
    fontWeight: '600',
    marginBottom: 8,
    color: '#333',
  },
  infoText: {
    fontSize: 12,
    color: '#6b7280',
    marginBottom: 4,
  },
  logContainer: {
    backgroundColor: '#1f2937',
    padding: 16,
    borderRadius: 10,
    minHeight: 200,
  },
  logLabel: {
    fontSize: 16,
    fontWeight: '600',
    marginBottom: 10,
    color: '#fff',
  },
  logContent: {
    fontFamily: 'monospace',
    fontSize: 12,
    color: '#9ca3af',
  },
});

export default ScanScreen;
