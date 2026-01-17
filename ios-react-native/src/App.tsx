import React from 'react';
import {NavigationContainer} from '@react-navigation/native';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import PairingScreen from './screens/PairingScreen';
import ScanScreen from './screens/ScanScreen';

export type RootStackParamList = {
  Pairing: undefined;
  Scan: {laptopIP: string; token: string};
};

const Stack = createNativeStackNavigator<RootStackParamList>();

function App(): React.JSX.Element {
  return (
    <NavigationContainer>
      <Stack.Navigator initialRouteName="Pairing">
        <Stack.Screen
          name="Pairing"
          component={PairingScreen}
          options={{headerShown: false}}
        />
        <Stack.Screen
          name="Scan"
          component={ScanScreen}
          options={{title: 'RoomScan Remote'}}
        />
      </Stack.Navigator>
    </NavigationContainer>
  );
}

export default App;
