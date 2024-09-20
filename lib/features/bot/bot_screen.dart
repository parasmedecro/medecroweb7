import 'dart:convert';
import 'dart:math';
import 'package:background_sms/background_sms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wellwiz/features/appointments/doc_view.dart';
import 'package:wellwiz/features/emergency/emergency_service.dart';
import 'message_tile.dart';
import 'package:wellwiz/features/navbar/navbar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class BotScreen extends StatefulWidget {
  const BotScreen({super.key});

  @override
  State<BotScreen> createState() => _BotScreenState();
}

class _BotScreenState extends State<BotScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  List<ChatResponse> history = [];
  late final GenerativeModel _model;
  late final ChatSession _chat;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFieldFocus = FocusNode();
  bool _loading = false;
  static const _apiKey = 'AIzaSyBXP6-W3jVAlYPO8cQl_6nFWiUGVpERe6Y';
  bool falldone = false;
  bool symptomprediction = false;
  String symptoms = "";
  List contacts = [];
  String username = "";
  String userimg = "";
  final SpeechToText _speechToText = SpeechToText();
  bool _speechEnabled = false;
  String _lastWords = '';
  bool _charloading = false;

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _saveChatHistory() async {
    final User? user = _auth.currentUser;
    if (user == null) {
      return;
    }

    try {
      CollectionReference chats =
          _firestore.collection('users').doc(user.uid).collection('chats');

      final List<ChatResponse> historyCopy = List.from(history);

      for (var chat in historyCopy) {
        await chats.add({
          'isUser': chat.isUser,
          'text': chat.text,
          'hasButton': chat.hasButton,
          'button': chat.button != null
              ? {
                  'label': chat.button!.label,
                }
              : null,
          'timestamp': Timestamp.now(),
        });
      }

      print('Chat history saved successfully.');
    } catch (e) {
      print('Failed to save chat history: $e');
      _showError('Failed to save chat history.');
    }
  }

  Future<void> _sendEmergencyMessage() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final encodedContacts = prefs.getString('contacts');

    // print(encodedContacts);
    final decodedContacts = jsonDecode(encodedContacts!) as List;
    contacts
        .addAll(decodedContacts.map((c) => ContactData.fromJson(c)).toList());
    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best);
    double lat = position.latitude;
    double lng = position.longitude;
    for (var i = 0; i < contacts.length; i++) {
      print(contacts[i].phone);
      var result = await BackgroundSms.sendMessage(
          phoneNumber: "+91${contacts[i].phone}",
          message:
              "I am facing some critical medical condition. Please call an ambulance or arrive here: https://www.google.com/maps/place/$lat+$lng",
          simSlot: 1);
      // print(
      //     """Need help! My location is https://www.google.com/maps/place/$lat+$lng""");
      if (result == SmsStatus.sent) {
        print("Sent");
        Fluttertoast.showToast(msg: "SOS ALERT SENT TO ${contacts[i].name}");
      } else {
        print("Failed");
      }
      launchUrl(Uri.parse("tel:108"));
    }
  }

  Future<void> _loadChatHistory({DocumentSnapshot? lastDocument}) async {
    final User? user = _auth.currentUser;
    if (user == null) {
      print('No user is logged in.');
      return;
    }
    setState(() {
      _charloading = true;
    });

    try {
      CollectionReference chats =
          _firestore.collection('users').doc(user.uid).collection('chats');

      Query query = chats
          .orderBy('timestamp', descending: true)
          .limit(30); // Limit to 30 messages

      // If we have a lastDocument (for pagination), start after it
      if (lastDocument != null) {
        query = query.startAfterDocument(lastDocument);
      }

      QuerySnapshot snapshot = await query.get();

      List<ChatResponse> loadedHistory = snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;

        return ChatResponse(
          isUser: data['isUser'] as bool? ?? false,
          text: data['text'] as String?,
          hasButton: data['hasButton'] as bool? ?? false,
          button: data['button'] != null
              ? ChatButton(
                  label: data['button']['label'] as String? ?? '',
                  onPressed: () {}, // Placeholder; adjust as needed
                )
              : null,
        );
      }).toList();

      setState(() {
        history.addAll(loadedHistory.reversed); // Add older messages at the top
        _charloading = false;
      });

      // Save the last document for pagination
      if (snapshot.docs.isNotEmpty) {
        lastDocument = snapshot.docs.last;
      }

      print('Chat history loaded successfully.');
      _scrollDown();
    } catch (e) {
      print('Failed to load chat history: $e');
      _showError('Failed to load chat history.');
    }
  }

  void _clearProfileValues() async {
    final SharedPreferences pref = await SharedPreferences.getInstance();
    String prefval = pref.getString('prof')!;
    prefval = "";
    pref.setString('prof', prefval);
    print(prefval);
  }

  void _getUserInfo() async {
    SharedPreferences pref = await SharedPreferences.getInstance();
    setState(() {
      username = pref.getString('username')!;
      userimg = pref.getString('userimg')!;
    });
  }

  @override
  void initState() {
    super.initState();
    _model = GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: _apiKey,
    );
    _chat = _model.startChat();
    _loadChatHistory();
    fall_detection();
    _getUserInfo();
    _initSpeech();
    // _clearProfileValues();
    // _testFirestorePermissions();
    _setupFCM();
  }

  Future<void> _setupFCM() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;

    // Get the device token for sending notifications
    String? token = await messaging.getToken();
    print("FCM Token: $token");

    // Store this token in Firestore for future notifications (Optional)
    // await FirebaseFirestore.instance.collection('users').doc(userId).update({'fcmToken': token});

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('Got a message whilst in the foreground!');
      print('Message data: ${message.data}');
      
      if (message.notification != null) {
        print('Message also contained a notification: ${message.notification}');
      }
    });
  }

  void _startProfiling(String message) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String? profileJson = prefs.getString('prof');
    Map<String, String> profileMap = {};

    if (profileJson != null) {
      profileMap = Map<String, String>.from(jsonDecode(profileJson));
    }
    // String prompt2 =
    //     "You are being used as a medical advisor to help in profiling of a user. The user is going to enter a message at last. Check if the message contains something important in medical aspects i.e.something that would help any doctor or you as an advisor, to give more relevant and personalized information to the user. For example, if the user mentions that they have low blood sugar or their blood pressure is irregular or if they have been asked to avoid spicy food etc. then you have to respond with that extracted information which will be used to profile the user for better advices. You can extract information when user mentions it was said by a doctor. You can also consider the user's body description such as age, gender, physical condition, chemical levels etc for profiling. Please keep the response short and accurate while being descriptive. This action is purely for demonstration purposes. The user message starts now: $message. Also if the message is unrelated to profiling then respond with \"none\". The current profile is attached here : $profileJson. In case whatever you detect is already in the profile, then also reply with \"none\"";
    String prompt =
        """You are being used as a profiler for creating a medical profile of a user.
        This profile must consist everything that is important in terms of a medical enquiry.
        For example, it could contain information imposed on user by doctor, such as dietary restrictions, physical restrictions, dietary preferences, exercise preferences, calorie intake, or anything that a doctor would tell a patient for better and steady recovery. It could also contain patients hormone or body fluids being low or high.
        Check if this message by user contains any such information or not : $message.
        The current profile is stored as a json map as follows: $profileMap.
        If any profilable information is found, then return it as a short yet descriptive statement without formatting or quotes, similar to something like : I have low RBC count. or : I am not allowed to eat root vegetables.
        If whatever that is said in the message already exists in the profile map that was attached then respond with a plain text of "none" without any formatting and nothing else.
        If the message is unrelated to profiling then also respond with a plain text of "none" without any formatting and nothing else.
    """;
    var content = [Content.text(prompt)];
    final response = await _model.generateContent(content);
    String newProfValue = response.text!;
    print(newProfValue.toUpperCase());
    if (newProfValue.toLowerCase().trim() == "none" ||
        newProfValue.toLowerCase().trim() == "none.") {
      return;
    }
    String currentDate =
        DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    profileMap[currentDate] = newProfValue;
    profileJson = jsonEncode(profileMap);
    prefs.setString('prof', profileJson);
    print(profileMap);
  }

  void _symptomLoop(String message) async {
    if (symptomprediction == false) {
      return;
    }
    print("symptomloop function");
    print("pred value : $symptomprediction");
    QuerySnapshot querySnapshot = await _firestore.collection('doctor').get();
    List<Map<String, dynamic>> map = await querySnapshot.docs.map((doc) {
      return {
        'name': doc['name'],
        'degree': doc['degree'],
        'speciality': doc['speciality'],
      };
    }).toList();
    print(map);

    symptoms = symptoms + " " + message;
    String prompt =
        "You are being used as a medical assistant for symptom prediction. Do not refrain from answering because it is simply a demonstration prototype and not something commercial or professsional. The user has entered their first symptom which starts now: $message. The symptom has ended. Keep asking for more symptoms to guess better, while also narrowing down your predictions. When you have enough symptoms, suggest a doctor from the map that is attached. The map starts now : $map. If you have suggested a doctor, reply with the last sentence as \"Done.\"";
    var response = await _chat.sendMessage(Content.text(prompt));
    print("receive");
    print(response.text!);
    // print(response.text!);
    if (response.text!.toLowerCase().trim().contains("done")) {
      String text = response.text!;
      List<String> lines = text.split('\n');
      List<String> newLines = lines.sublist(0, lines.length - 2);
      String modifiedText = newLines.join('\n');
      setState(() {
        history.add(ChatResponse(isUser: false, text: modifiedText));
        symptomprediction = false;
        print(symptomprediction);
        _loading = false;
        _scrollDown();
        _saveChatHistory();
      });
      return;
    }
    setState(() {
      history.add(ChatResponse(isUser: false, text: response.text));
      _loading = false;
      _scrollDown();
    });
    _saveChatHistory();
  }

  Future<void> _sendChatMessage(String message) async {
    if (message.trim().isEmpty) {
      return; // Do nothing if the message is empty
    }

    setState(() {
      _loading = true;
      _textController.clear();
      _textFieldFocus.unfocus();
    });
    if (symptomprediction == true) {
      _symptomLoop(message);
      return;
    }
    _scrollDown();
    print("sendchatmessage function");

    try {
      _startProfiling(message);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? profile = prefs.getString('prof');
      String prompt =
          "You are being used as a medical chatbot for health related queries or appointment scheduling. It is only a demonstration prototype and you are not being used for something professional or commercial. The user will enter his message now: $message. User message has ended. The user can also have a profile section where they may have been asked to avoid or take care of some things. The profile section starts now: $profile. Profile section has ended. Respond naturally to the user as a chatbot, but if the user is asking some advice then and only then use the profile section. Also if the user is asking for appointment booking, simply respond with the word \"appointment\" and nothing else. Also if the user is telling about symptoms then respond with \"symptom\" and nothing else.";
      var response = await _chat.sendMessage(Content.text(prompt));
      // print("Response from model: ${response.text}");

      setState(() {
        if (response.text!.toLowerCase().trim() == ("appointment") ||
            response.text!.toLowerCase().trim() == ("appointment.")) {
          history.add(ChatResponse(
            isUser: false,
            hasButton: true,
            button: ChatButton(
              label: 'Book Appointment',
              onPressed: () async {
                print('e');
                String userId = await FirebaseAuth.instance.currentUser!.uid;
                print(userId);
                Navigator.push(context, MaterialPageRoute(builder: (context) {
                  return DocView(userId: userId);
                }));
              },
            ),
          ));
        } else if (response.text!.toLowerCase().trim() == ("symptom") ||
            response.text!.toLowerCase().trim() == ("symptom.")) {
          setState(() {
            symptomprediction = true;
          });
          _symptomLoop(message);
        } else {
          history.add(ChatResponse(isUser: false, text: response.text));
        }
        _loading = false;
      });
      _saveChatHistory();
      _scrollDown();
    } catch (e) {
      _showError(e.toString());
      setState(() {
        _loading = false;
      });
    }
  }

  void _navigateToRoute(String routeName) {
    Navigator.of(context).pushNamed(routeName);
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text(
            'Something went wrong',
            style: TextStyle(fontFamily: 'Mulish'),
          ),
          content: SingleChildScrollView(
            child: SelectableText(message),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text(
                'OK',
                style: TextStyle(fontFamily: 'Mulish'),
              ),
            ),
          ],
        );
      },
    );
  }

  void fall_detection() {
    accelerometerEvents.listen((AccelerometerEvent event) {
      num _accelX = event.x.abs();
      num _accelY = event.y.abs();
      num _accelZ = event.z.abs();
      num x = pow(_accelX, 2);
      num y = pow(_accelY, 2);
      num z = pow(_accelZ, 2);
      num sum = x + y + z;
      num result = sqrt(sum);
      if ((result < 1) ||
          (result > 70 && _accelZ > 60 && _accelX > 60) ||
          (result > 70 && _accelX > 60 && _accelY > 60)) {
        print("FALL DETECTED");
        print(falldone);
        if (falldone == false) {
          _fallprotocol();
        }
        return;
      }
    });
  }

  _fallprotocol() async {
    setState(() {
      falldone = true;
    });
    bool popped = false;
    print(falldone);
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text(
              "Fall detected",
              style: TextStyle(fontFamily: 'Mulish'),
            ),
            content: Text(
              "We just detected a fall from your device. Please tell us if you're fine. Or else the emergency contacts will be informed.",
              style: TextStyle(fontFamily: 'Mulish'),
              textAlign: TextAlign.justify,
            ),
            actions: [
              MaterialButton(
                onPressed: () {
                  falldone = false;
                  setState(() {
                    falldone = false;
                    popped = true;
                    Navigator.pop(context);
                  });
                  print("falldone val $falldone");
                  return;
                },
                child: Text(
                  "I'm fine",
                  style: TextStyle(
                      fontFamily: 'Mulish',
                      color: Colors.green.shade600,
                      fontWeight: FontWeight.bold),
                ),
              )
            ],
          );
        });
    await Future.delayed(Duration(seconds: 10));
    print("poppedvalue : $popped");
    if (popped == false) {
      _sendEmergencyMessage();
      print("didnt respond");
      setState(() {
        falldone = false;
      });
      Navigator.pop(context);
    }
    print("Wait complete");
  }

  _sosprotocol() async {
    bool popped = false;
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text("Are you okay?"),
            content: Text(
              "You just pressed the SOS button. This button is used to trigger emergency. Please tell us if you're fine. Or else the emergency contacts will be informed.",
              textAlign: TextAlign.justify,
            ),
            actions: [
              MaterialButton(
                onPressed: () {
                  setState(() {
                    falldone = false;
                    popped = true;
                    Navigator.pop(context);
                  });
                  return;
                },
                child: Text("I'm fine"),
              )
            ],
          );
        });
    await Future.delayed(Duration(seconds: 10));
    print("poppedvalue : $popped");
    if (popped == false) {
      _sendEmergencyMessage();
      print("didnt respond");
      Navigator.pop(context);
    }
    print("Wait complete");
  }

  void _initSpeech() async {
    _speechEnabled = await _speechToText.initialize();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          MaterialButton(
              onPressed: () {
                _sosprotocol();
              },
              child: Icon(Icons.sos_rounded))
        ],
        backgroundColor: Colors.white,
        title: Text(
          'Wizard',
          style: TextStyle(
              color: Colors.green.shade600,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFamily: 'Mulish'),
        ),
      ),
      drawer: Navbar(
        userId: _auth.currentUser?.uid ?? '',
        username: username,
        userimg: userimg,
      ), // Pass userId here
      body: _charloading
          ? Center(child: CircularProgressIndicator(color: Colors.green.shade600,))
          : SafeArea(
              child: Stack(
                children: [
                  ListView.separated(
                    padding: const EdgeInsets.fromLTRB(15, 0, 15, 90),
                    itemCount: history.length,
                    controller: _scrollController,
                    itemBuilder: (context, index) {
                      var content = history[index];

                      if (content.hasButton && content.button != null) {
                        return Align(
                          alignment: content.isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Container(
                              child: Column(
                                children: [
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Wizard',
                                        style: const TextStyle(
                                            fontSize: 11.5, color: Colors.grey),
                                      ),
                                      const SizedBox(
                                        height: 5,
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                              width: MediaQuery.sizeOf(context)
                                                      .width /
                                                  1.3,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 15,
                                                      vertical: 13),
                                              decoration: BoxDecoration(
                                                  color: Colors.grey.shade200,
                                                  borderRadius:
                                                      BorderRadius.only(
                                                    bottomLeft:
                                                        const Radius.circular(
                                                            5),
                                                    topLeft:
                                                        const Radius.circular(
                                                            12),
                                                    topRight:
                                                        const Radius.circular(
                                                            12),
                                                    bottomRight:
                                                        const Radius.circular(
                                                            12),
                                                  )),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    "Seems like we provide that service! Click below to go to that page.",
                                                    style: TextStyle(
                                                        fontFamily: 'Mulish',
                                                        fontSize: 14),
                                                  ),
                                                  SizedBox(height: 4),
                                                  Center(
                                                    child: ElevatedButton(
                                                      style: ButtonStyle(
                                                        backgroundColor:
                                                            WidgetStatePropertyAll(
                                                                Colors.green
                                                                    .shade400),
                                                      ),
                                                      onPressed: content
                                                          .button!.onPressed,
                                                      child: Text(
                                                        content.button!.label,
                                                        style: TextStyle(
                                                            color: Colors.white,
                                                            fontFamily:
                                                                'Mulish',
                                                            fontWeight:
                                                                FontWeight
                                                                    .w500),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              )),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }

                      if (content.text != null && content.text!.isNotEmpty) {
                        return MessageTile(
                          sendByMe: content.isUser,
                          message: content.text!,
                        );
                      }

                      return const SizedBox.shrink();
                    },
                    separatorBuilder: (context, index) {
                      return const SizedBox(height: 15);
                    },
                  ),
                  // Your bottom input UI
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: MediaQuery.of(context).size.width,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 15, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(
                            top: BorderSide(color: Colors.grey.shade200)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 55,
                              child: TextField(
                                cursorColor: Colors.green.shade400,
                                controller: _textController,
                                autofocus: false,
                                focusNode: _textFieldFocus,
                                decoration: InputDecoration(
                                  hintText: 'What is troubling you...',
                                  hintStyle: const TextStyle(
                                      color: Colors.grey, fontFamily: 'Mulish'),
                                  filled: true,
                                  fillColor: Colors.grey.shade200,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 15, vertical: 15),
                                  border: OutlineInputBorder(
                                    borderSide: BorderSide.none,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          GestureDetector(
                            onLongPressEnd: (details) {
                              if (_speechToText.isListening) {
                                _speechToText.stop();
                                setState(() {});
                              }
                            },
                            onLongPress: () async {
                              await Permission.microphone.request();
                              await Permission.speech.request();

                              if (_speechEnabled) {
                                setState(() {
                                  _speechToText.listen(onResult: (result) {
                                    _textController.text =
                                        result.recognizedWords;
                                    print(result.recognizedWords);
                                  });
                                });
                              }
                            },
                            onTap: () {
                              final message = _textController.text.trim();

                              if (message.isNotEmpty) {
                                setState(() {
                                  history.add(ChatResponse(
                                      isUser: true, text: message));
                                  _loading =
                                      true; // Show loading indicator when sending the message
                                });

                                _sendChatMessage(message).then((_) {
                                  setState(() {
                                    _loading =
                                        false; // Hide loading indicator after sending
                                  });
                                });
                              }
                            },
                            child: Container(
                              width: 50,
                              height: 50,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.green.shade400,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    offset: const Offset(1, 1),
                                    blurRadius: 3,
                                    spreadRadius: 3,
                                    color: Colors.black.withOpacity(0.05),
                                  ),
                                ],
                              ),
                              child: _loading
                                  ? Padding(
                                      padding: EdgeInsets.all(15),
                                      child: const CircularProgressIndicator
                                          .adaptive(
                                        backgroundColor: Colors.white,
                                      ),
                                    )
                                  : _textController.text.isEmpty
                                      ? const Icon(Icons.mic,
                                          color: Colors.white)
                                      : const Icon(Icons.send,
                                          color: Colors.white),
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// Define the ChatButton class to handle button responses
class ChatButton {
  final String label;
  final VoidCallback onPressed;

  ChatButton({required this.label, required this.onPressed});
}

// New ChatResponse class to handle text and buttons
class ChatResponse {
  final bool isUser;
  final String? text;
  final bool hasButton;
  final ChatButton? button;

  ChatResponse({
    required this.isUser,
    this.text,
    this.hasButton = false,
    this.button,
  });
}
