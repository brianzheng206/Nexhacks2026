import React, {useState} from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
  ActivityIndicator,
} from 'react-native';
import {NativeStackScreenProps} from '@react-navigation/native-stack';
import {RootStackParamList} from '../App';
import QRScanner from '../components/QRScanner';
import WSClient from '../services/WSClient';
import {RoomPlanModule} from '../native/RoomPlanModule';

type Props = NativeStackScreenProps<RootStackParamList, 'Pairing'>;

const PairingScreen: React.FC<Props> = ({navigation}) => {
  const [laptopIP, setLaptopIP] = useState('');
  const [token, setToken] = useState('');
  const [isConnecting, setIsConnecting] = useState(false);
  const [showQRScanner, setShowQRScanner] = useState(false);

  const validateIP = (ip: string): boolean => {
    const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
    if (!ipRegex.test(ip)) {
      return false;
    }
    const parts = ip.split('.').map(Number);
    return parts.every(part => part >= 0 && part <= 255);
  };

  const handleConnect = async () => {
    if (!laptopIP.trim() || !token.trim()) {
      Alert.alert('Error', 'Please enter both IP address and token');
      return;
    }

    if (!validateIP(laptopIP)) {
      Alert.alert('Error', 'Invalid IP address format');
      return;
    }

    setIsConnecting(true);

    try {
      const success = await WSClient.shared.connect(laptopIP, token);
      if (success) {
        // Set laptop IP in RoomPlan module for uploads
        RoomPlanModule.setLaptopIP(laptopIP);
        navigation.navigate('Scan', {laptopIP, token});
      } else {
        Alert.alert('Connection Failed', 'Could not connect to server');
      }
    } catch (error) {
      Alert.alert(
        'Error',
        error instanceof Error ? error.message : 'Connection failed',
      );
    } finally {
      setIsConnecting(false);
    }
  };

  const handleQRScanned = (
    scannedToken: string | null,
    scannedHost: string | null,
  ) => {
    if (scannedToken) {
      setToken(scannedToken);
    }
    if (scannedHost) {
      setLaptopIP(scannedHost);
    }
    setShowQRScanner(false);
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>RoomScan Remote</Text>

      <View style={styles.inputGroup}>
        <Text style={styles.label}>Laptop IP Address</Text>
        <TextInput
          style={styles.input}
          placeholder="e.g., 192.168.1.100"
          value={laptopIP}
          onChangeText={setLaptopIP}
          keyboardType="numbers-and-punctuation"
          autoCapitalize="none"
          autoCorrect={false}
        />
      </View>

      <View style={styles.inputGroup}>
        <Text style={styles.label}>Session Token</Text>
        <TextInput
          style={styles.input}
          placeholder="Enter token"
          value={token}
          onChangeText={setToken}
          autoCapitalize="none"
          autoCorrect={false}
        />
      </View>

      <TouchableOpacity
        style={[styles.button, styles.qrButton]}
        onPress={() => setShowQRScanner(true)}>
        <Text style={styles.buttonText}>📷 Scan QR Code</Text>
      </TouchableOpacity>

      <TouchableOpacity
        style={[
          styles.button,
          styles.connectButton,
          (isConnecting || !laptopIP || !token) && styles.buttonDisabled,
        ]}
        onPress={handleConnect}
        disabled={isConnecting || !laptopIP || !token}>
        {isConnecting ? (
          <ActivityIndicator color="#fff" />
        ) : (
          <Text style={styles.buttonText}>Connect</Text>
        )}
      </TouchableOpacity>

      {showQRScanner && (
        <QRScanner
          onScanned={handleQRScanned}
          onCancel={() => setShowQRScanner(false)}
        />
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 20,
    backgroundColor: '#fff',
    justifyContent: 'center',
  },
  title: {
    fontSize: 32,
    fontWeight: 'bold',
    textAlign: 'center',
    marginBottom: 40,
    color: '#333',
  },
  inputGroup: {
    marginBottom: 20,
  },
  label: {
    fontSize: 16,
    fontWeight: '600',
    marginBottom: 8,
    color: '#333',
  },
  input: {
    borderWidth: 1,
    borderColor: '#ddd',
    borderRadius: 8,
    padding: 12,
    fontSize: 16,
    backgroundColor: '#fff',
  },
  button: {
    padding: 16,
    borderRadius: 10,
    alignItems: 'center',
    marginTop: 10,
  },
  qrButton: {
    backgroundColor: '#10b981',
  },
  connectButton: {
    backgroundColor: '#3b82f6',
  },
  buttonDisabled: {
    backgroundColor: '#9ca3af',
  },
  buttonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});

export default PairingScreen;
