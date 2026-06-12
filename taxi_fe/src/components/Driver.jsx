import {useEffect, useState} from 'react';
import Button from '@mui/material/Button';

import socket from '../services/taxi_socket';
import { Card, CardContent, Typography } from '@mui/material';

function Driver(props) {
  let [message, setMessage] = useState();
  let [bookingId, setBookingId] = useState();
  let [visible, setVisible] = useState(false);
  let [notice, setNotice] = useState("");

  useEffect(() => {
    const topic = "driver:" + props.username;
    const channel = socket.channel(topic, {token: "123"});

    channel.on("booking_request", data => {
      console.log("Received", data);
      setMessage(data.msg);
      setBookingId(data.bookingId);
      setVisible(true);
      setNotice("");
    });
    channel.on("booking_closed", () => {
      setVisible(false);
    });
    channel.on("booking_cancelled", data => {
      setVisible(false);
      setNotice(data.msg);
    });

    channel.join()
      .receive("ok", () => console.log(`Joined ${topic}`))
      .receive("error", response => console.error(`Unable to join ${topic}`, response))
      .receive("timeout", () => console.error(`Timed out joining ${topic}`));

    return () => {
      channel.leave();
    };
  }, [props.username]);

  let reply = (decision) => {
    fetch(`http://localhost:4000/api/bookings/${bookingId}`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({action: decision, username: props.username})
    }).then(response => {
      if (!response.ok) {
        throw new Error(`Backend returned ${response.status}`);
      }

      setVisible(false);
    }).catch(error => {
      console.error(`Unable to ${decision} booking ${bookingId}`, error);
    });
  };

  return (
    <div style={{textAlign: "center", borderStyle: "solid"}}>
        Driver: {props.username}
        <div style={{backgroundColor: "lavender", height: "100px"}}>
          {
            visible ?
            <Card variant="outlined" style={{margin: "auto", width: "600px"}}>
              <CardContent>
                <Typography>
                {message}
                </Typography>
              </CardContent>
              <Button onClick={() => reply("accept")} variant="outlined" color="primary">Accept</Button>
              <Button onClick={() => reply("reject")} variant="outlined" color="secondary">Reject</Button>
            </Card> :
            null
          }
        </div>
        <div>{notice}</div>
    </div>
  );
}

export default Driver;
