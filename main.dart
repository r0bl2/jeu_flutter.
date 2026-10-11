import 'package:flutter/material.dart';
import 'package:postgres/postgres.dart';
import 'dart:math';
import 'dart:async';

void main() {
  runApp(const StickmanFighterGame());
}

class StickmanFighterGame extends StatelessWidget {
  const StickmanFighterGame({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stickman Fighter',
      theme: ThemeData(
        primarySwatch: Colors.red,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const LoginScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ==================== MODÈLES ====================

class Player {
  final int id;
  final String username;
  int totalXp;
  int currentLevel;
  int totalWins;
  int totalGames;
  Map<String, int> combatStats;
  List<String> unlockedSkills;

  Player({
    required this.id,
    required this.username,
    this.totalXp = 0,
    this.currentLevel = 1,
    this.totalWins = 0,
    this.totalGames = 0,
    this.combatStats = const {},
    this.unlockedSkills = const [],
  });

  int get requiredXpForNextLevel => currentLevel * 1000;
  int get xpProgress => totalXp - ((currentLevel - 1) * 1000);
}

// ==================== SERVICE POSTGRESQL ====================

class PostgresService {
  static final PostgresService _instance = PostgresService._internal();
  factory PostgresService() => _instance;
  PostgresService._internal();

  late PostgreSQLConnection connection;
  bool _isConnected = false;

  Future<void> connect() async {
    if (_isConnected) return;
    
    connection = PostgreSQLConnection(
      'localhost', // Remplacez par votre IP PostgreSQL
      5432,
      'stickman_game',
      username: 'postgres',
      password: 'postgresql',
      useSSL: false,
    );
    await connection.open();
    _isConnected = true;
    print('Connecté à PostgreSQL');
  }

  Future<Map<String, dynamic>?> login(String username, String password) async {
    await connect();
    
    final result = await connection.query(
      'SELECT * FROM players WHERE username = @username',
      substitutionValues: {'username': username},
    );

    if (result.isNotEmpty) {
      final player = result.first;
      if (player['password_hash'] == password) {
        // Mettre à jour last_login
        await connection.query(
          'UPDATE players SET last_login = CURRENT_TIMESTAMP WHERE id = @id',
          substitutionValues: {'id': player['id']},
        );
        
        return {
          'id': player['id'],
          'username': player['username'],
          'total_xp': player['total_xp'],
          'current_level': player['current_level'],
          'total_wins': player['total_wins'],
          'total_games_played': player['total_games_played'],
        };
      }
    }
    return null;
  }

  Future<bool> register(String username, String email, String password) async {
    await connect();
    
    try {
      await connection.query(
        '''INSERT INTO players (username, email, password_hash, total_xp, current_level) 
           VALUES (@username, @email, @password, 0, 1)''',
        substitutionValues: {
          'username': username,
          'email': email,
          'password': password,
        },
      );
      
      final result = await connection.query(
        'SELECT id FROM players WHERE username = @username',
        substitutionValues: {'username': username},
      );
      
      final playerId = result.first['id'];
      
      await connection.query(
        '''INSERT INTO combat_stats (player_id, strength, agility, stamina, technique, special_power) 
           VALUES (@player_id, 10, 10, 10, 10, 5)''',
        substitutionValues: {'player_id': playerId},
      );
      
      return true;
    } catch (e) {
      print('Erreur inscription: $e');
      return false;
    }
  }

  Future<void> updatePlayerStats(int playerId, int xpGained, int wins, int maxCombo) async {
    await connect();
    
    await connection.query(
      '''UPDATE players 
         SET total_xp = total_xp + @xp,
             total_games_played = total_games_played + 1,
             total_wins = total_wins + @wins
         WHERE id = @player_id''',
      substitutionValues: {
        'xp': xpGained,
        'wins': wins,
        'player_id': playerId,
      },
    );

    await connection.query(
      '''INSERT INTO combat_history (player_id, opponent_name, result, combo_max) 
         VALUES (@player_id, 'AI_Opponent', @result, @combo_max)''',
      substitutionValues: {
        'player_id': playerId,
        'result': wins > 0 ? 'victory' : 'defeat',
        'combo_max': maxCombo,
      },
    );
  }

  Future<Map<String, dynamic>> getCombatStats(int playerId) async {
    await connect();
    
    final result = await connection.query(
      'SELECT * FROM combat_stats WHERE player_id = @player_id',
      substitutionValues: {'player_id': playerId},
    );
    
    if (result.isNotEmpty) {
      return result.first;
    }
    return {'strength': 10, 'agility': 10, 'stamina': 10, 'technique': 10, 'special_power': 5};
  }

  Future<List<String>> getUnlockedSkills(int playerId) async {
    await connect();
    
    final result = await connection.query(
      'SELECT skill_name FROM unlocked_skills WHERE player_id = @player_id',
      substitutionValues: {'player_id': playerId},
    );
    
    return result.map((row) => row['skill_name'] as String).toList();
  }

  Future<void> unlockSkill(int playerId, String skillName) async {
    await connect();
    
    await connection.query(
      '''INSERT INTO unlocked_skills (player_id, skill_name, skill_level) 
         VALUES (@player_id, @skill_name, 1)
         ON CONFLICT (player_id, skill_name) 
         DO UPDATE SET skill_level = unlocked_skills.skill_level + 1''',
      substitutionValues: {
        'player_id': playerId,
        'skill_name': skillName,
      },
    );
  }

  void disconnect() async {
    if (_isConnected) {
      await connection.close();
      _isConnected = false;
    }
  }
}

// ==================== SYSTÈME DE COMBAT ====================

class CombatSystem {
  int playerHealth = 100;
  int opponentHealth = 100;
  int combo = 0;
  int maxCombo = 0;
  bool isPlayerTurn = true;
  bool isGameActive = true;
  
  List<Map<String, dynamic>> combatLog = [];
  
  final Map<String, Map<String, dynamic>> moves = {
    'punch': {'damage': 10, 'stamina': 5, 'combo': 1, 'name': 'Poing', 'level': 1},
    'kick': {'damage': 15, 'stamina': 8, 'combo': 1, 'name': 'Pied', 'level': 1},
    'uppercut': {'damage': 20, 'stamina': 12, 'combo': 2, 'name': 'Uppercut', 'level': 2},
    'roundhouse': {'damage': 25, 'stamina': 15, 'combo': 2, 'name': 'Pied tournant', 'level': 3},
    'spinning_fist': {'damage': 30, 'stamina': 20, 'combo': 3, 'name': 'Poing tournant', 'level': 4},
    'dragon_kick': {'damage': 40, 'stamina': 25, 'combo': 3, 'name': 'Dragon Kick', 'level': 5},
  };
  
  Map<String, bool> unlockedSkills = {};
  
  CombatSystem() {
    unlockedSkills['punch'] = true;
    unlockedSkills['kick'] = true;
  }
  
  void unlockSkill(String skillName) {
    if (moves.containsKey(skillName)) {
      unlockedSkills[skillName] = true;
    }
  }
  
  bool playerAttack(String moveName, int strength, int technique) {
    if (!isGameActive || !isPlayerTurn) return false;
    if (!unlockedSkills[moveName]!) return false;
    
    final move = moves[moveName]!;
    
    int damage = (move['damage'] as int) + (strength ~/ 5);
    damage = (damage * (1 + technique / 100)).toInt();
    
    final random = Random();
    damage = damage + random.nextInt(10) - 5;
    damage = damage.clamp(5, 60);
    
    opponentHealth -= damage;
    opponentHealth = opponentHealth.clamp(0, 100);
    
    combo += move['combo'] as int;
    if (combo > maxCombo) maxCombo = combo;
    
    combatLog.add({
      'move': move['name'],
      'damage': damage,
      'combo': combo,
      'turn': 'player',
    });
    
    if (opponentHealth <= 0) {
      isGameActive = false;
      return true;
    }
    
    isPlayerTurn = false;
    return false;
  }
  
  void opponentTurn(int agility) {
    if (!isGameActive || isPlayerTurn) return;
    
    final random = Random();
    final availableMoves = ['punch', 'kick'];
    final moveName = availableMoves[random.nextInt(availableMoves.length)];
    final move = moves[moveName]!;
    
    int damage = move['damage'] as int;
    damage = damage + random.nextInt(15);
    
    final dodgeChance = agility / 100;
    if (random.nextDouble() < dodgeChance) {
      combatLog.add({
        'move': 'Esquive',
        'damage': 0,
        'combo': 0,
        'turn': 'opponent',
        'dodged': true,
      });
    } else {
      playerHealth -= damage;
      playerHealth = playerHealth.clamp(0, 100);
      
      combatLog.add({
        'move': move['name'],
        'damage': damage,
        'combo': 0,
        'turn': 'opponent',
      });
    }
    
    combo = 0;
    isPlayerTurn = true;
    
    if (playerHealth <= 0) {
      isGameActive = false;
    }
  }
  
  void reset() {
    playerHealth = 100;
    opponentHealth = 100;
    combo = 0;
    maxCombo = 0;
    isPlayerTurn = true;
    isGameActive = true;
    combatLog.clear();
  }
  
  bool isGameOver() => !isGameActive;
  bool isVictory() => opponentHealth <= 0;
  
  int calculateXpGained() {
    int xp = 50;
    if (isVictory()) {
      xp += 100;
      xp += maxCombo * 10;
      xp += (100 - playerHealth) ~/ 2;
    }
    return xp.clamp(50, 500);
  }
}

// ==================== WIDGETS ====================

class HealthBar extends StatelessWidget {
  final int health;
  final int maxHealth;
  
  const HealthBar({Key? key, required this.health, required this.maxHealth}) : super(key: key);
  
  @override
  Widget build(BuildContext context) {
    final percentage = health / maxHealth;
    return Container(
      width: 200,
      height: 20,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Stack(
        children: [
          Container(
            width: 200 * percentage,
            decoration: BoxDecoration(
              color: percentage > 0.6 ? Colors.green : (percentage > 0.3 ? Colors.orange : Colors.red),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          Center(
            child: Text(
              '$health / $maxHealth',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class CombatControls extends StatelessWidget {
  final Function(String) onMoveSelected;
  final List<String> unlockedSkills;
  
  const CombatControls({Key? key, required this.onMoveSelected, required this.unlockedSkills}) : super(key: key);
  
  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> moves = {
      'punch': {'icon': '👊', 'name': 'Poing', 'level': 1},
      'kick': {'icon': '🦶', 'name': 'Pied', 'level': 1},
      'uppercut': {'icon': '💪', 'name': 'Uppercut', 'level': 2},
      'roundhouse': {'icon': '🦵', 'name': 'Pied tournant', 'level': 3},
      'spinning_fist': {'icon': '🌀', 'name': 'Poing tournant', 'level': 4},
      'dragon_kick': {'icon': '🐉', 'name': 'Dragon Kick', 'level': 5},
    };
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Column(
        children: [
          const Text('ATTAQUES', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: moves.entries.map((entry) {
              final isUnlocked = unlockedSkills.contains(entry.key);
              return ElevatedButton.icon(
                onPressed: isUnlocked ? () => onMoveSelected(entry.key) : null,
                icon: Text(entry.value['icon']),
                label: Text(entry.value['name']),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isUnlocked ? Colors.red : Colors.grey,
                  foregroundColor: Colors.white,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Text(
            '💡 Astuce: Enchaînez les attaques pour faire monter le combo!',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class Stickman extends StatefulWidget {
  final bool isPlayer;
  final int health;
  final int maxHealth;
  final String animation;
  final Color color;

  const Stickman({
    Key? key,
    required this.isPlayer,
    required this.health,
    this.maxHealth = 100,
    this.animation = 'idle',
    this.color = Colors.black,
  }) : super(key: key);

  @override
  State<Stickman> createState() => _StickmanState();
}

class _StickmanState extends State<Stickman> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _attackAnimation;
  double _hitShake = 0.0;
  double _armAngle = 0.0;
  double _legAngle = 0.0;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    
    _attackAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    
    _animationController.addListener(() {
      setState(() {
        if (widget.animation == 'punch') {
          _armAngle = _attackAnimation.value * 1.5;
        } else if (widget.animation == 'kick') {
          _legAngle = _attackAnimation.value * 1.5;
        } else if (widget.animation == 'hit') {
          _hitShake = sin(_animationController.value * pi * 4) * 10;
        }
      });
    });
    
    _playAnimation();
  }
  
  void _playAnimation() {
    if (widget.animation != 'idle') {
      _animationController.forward(from: 0.0);
      Future.delayed(const Duration(milliseconds: 200), () {
        _animationController.stop();
        setState(() {
          _armAngle = 0.0;
          _legAngle = 0.0;
          _hitShake = 0.0;
        });
      });
    }
  }
  
  @override
  void didUpdateWidget(Stickman oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animation != oldWidget.animation && widget.animation != 'idle') {
      _playAnimation();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(_hitShake, 0),
      child: CustomPaint(
        size: const Size(200, 300),
        painter: StickmanPainter(
          isPlayer: widget.isPlayer,
          health: widget.health,
          maxHealth: widget.maxHealth,
          armAngle: _armAngle,
          legAngle: _legAngle,
          color: widget.color,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }
}

class StickmanPainter extends CustomPainter {
  final bool isPlayer;
  final int health;
  final int maxHealth;
  final double armAngle;
  final double legAngle;
  final Color color;

  StickmanPainter({
    required this.isPlayer,
    required this.health,
    required this.maxHealth,
    required this.armAngle,
    required this.legAngle,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    
    // Tête
    canvas.drawCircle(Offset(centerX, centerY - 60), 30, paint);
    
    // Yeux
    final eyeOffset = isPlayer ? -12 : 12;
    canvas.drawCircle(Offset(centerX - 10 + eyeOffset, centerY - 70), 3, paint);
    canvas.drawCircle(Offset(centerX + 10 + eyeOffset, centerY - 70), 3, paint);
    
    // Bouche (sourire ou triste selon santé)
    final mouthY = centerY - 55;
    if (health > 50) {
      canvas.drawArc(
        Rect.fromCenter(center: Offset(centerX, mouthY), width: 20, height: 15),
        0, pi, false, paint,
      );
    } else {
      canvas.drawArc(
        Rect.fromCenter(center: Offset(centerX, mouthY), width: 20, height: 15),
        pi, pi, false, paint,
      );
    }
    
    // Corps
    canvas.drawLine(
      Offset(centerX, centerY - 30),
      Offset(centerX, centerY + 50),
      paint,
    );
    
    // Bras avec animation
    final leftArmAngle = -pi / 4 + (armAngle * pi / 2);
    final rightArmAngle = pi / 4 - (armAngle * pi / 2);
    
    canvas.drawLine(
      Offset(centerX, centerY - 10),
      Offset(centerX - 60 * cos(leftArmAngle), centerY - 10 - 60 * sin(leftArmAngle)),
      paint,
    );
    canvas.drawLine(
      Offset(centerX, centerY - 10),
      Offset(centerX + 60 * cos(rightArmAngle), centerY - 10 - 60 * sin(rightArmAngle)),
      paint,
    );
    
    // Jambes avec animation
    final leftLegAngle = pi / 3 + (legAngle * pi / 3);
    final rightLegAngle = -pi / 3 - (legAngle * pi / 3);
    
    canvas.drawLine(
      Offset(centerX, centerY + 50),
      Offset(centerX - 50 * cos(leftLegAngle), centerY + 50 + 50 * sin(leftLegAngle)),
      paint,
    );
    canvas.drawLine(
      Offset(centerX, centerY + 50),
      Offset(centerX + 50 * cos(rightLegAngle), centerY + 50 + 50 * sin(rightLegAngle)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ==================== ÉCRANS ====================

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _isRegistering = false;

  Future<void> _handleAuth() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isLoading = true);
    
    final service = PostgresService();
    
    if (_isRegistering) {
      // Pour l'inscription, on utilise un email par défaut
      final success = await service.register(
        _usernameController.text,
        '${_usernameController.text}@email.com',
        _passwordController.text,
      );
      
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Inscription réussie! Connectez-vous maintenant.')),
        );
        setState(() => _isRegistering = false);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Erreur lors de l\'inscription')),
        );
      }
    } else {
      final player = await service.login(_usernameController.text, _passwordController.text);
      
      if (player != null) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => GameScreen(player: Player.fromJson(player)),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Identifiants incorrects')),
        );
      }
    }
    
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.red, Colors.orange],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Card(
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sports_mma, size: 80, color: Colors.red),
                      const SizedBox(height: 20),
                      Text(
                        _isRegistering ? 'Inscription' : 'Stickman Fighter',
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 30),
                      TextFormField(
                        controller: _usernameController,
                        decoration: const InputDecoration(
                          labelText: 'Nom d\'utilisateur',
                          prefixIcon: Icon(Icons.person),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v!.isEmpty ? 'Champ requis' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Mot de passe',
                          prefixIcon: Icon(Icons.lock),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v!.isEmpty ? 'Champ requis' : null,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _handleAuth,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                        ),
                        child: _isLoading
                            ? const CircularProgressIndicator()
                            : Text(_isRegistering ? 'S\'inscrire' : 'Se connecter'),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _isRegistering = !_isRegistering),
                        child: Text(_isRegistering ? 'Déjà un compte? Connectez-vous' : 'Pas de compte? Inscrivez-vous'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GameScreen extends StatefulWidget {
  final Player player;
  
  const GameScreen({Key? key, required this.player}) : super(key: key);

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with SingleTickerProviderStateMixin {
  late CombatSystem _combat;
  late AnimationController _hitController;
  String _playerAnimation = 'idle';
  String _opponentAnimation = 'idle';
  Map<String, dynamic> _playerStats = {};
  List<String> _unlockedSkills = [];
  bool _isAITurn = false;

  @override
  void initState() {
    super.initState();
    _combat = CombatSystem();
    _hitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _loadPlayerData();
  }
  
  Future<void> _loadPlayerData() async {
    final stats = await PostgresService().getCombatStats(widget.player.id);
    final skills = await PostgresService().getUnlockedSkills(widget.player.id);
    
    setState(() {
      _playerStats = stats;
      _unlockedSkills = skills;
    });
    
    for (var skill in skills) {
      _combat.unlockSkill(skill);
    }
  }
  
  Future<void> _performMove(String moveName) async {
    if (_combat.isGameOver() || _isAITurn) return;
    
    setState(() {
      _playerAnimation = moveName.contains('kick') ? 'kick' : 'punch';
    });
    
    final victory = _combat.playerAttack(
      moveName,
      _playerStats['strength'] ?? 10,
      _playerStats['technique'] ?? 10,
    );
    
    if (victory) {
      await _endBattle(true);
      return;
    }
    
    await Future.delayed(const Duration(milliseconds: 400));
    setState(() => _playerAnimation = 'idle');
    
    // Tour de l'IA
    setState(() {
      _isAITurn = true;
      _opponentAnimation = 'punch';
    });
    
    await Future.delayed(const Duration(milliseconds: 300));
    
    _combat.opponentTurn(_playerStats['agility'] ?? 10);
    
    if (_combat.playerHealth <= 0) {
      await _endBattle(false);
      return;
    }
    
    await Future.delayed(const Duration(milliseconds: 300));
    
    setState(() {
      _opponentAnimation = 'idle';
      _isAITurn = false;
    });
  }
  
  Future<void> _endBattle(bool isVictory) async {
    final xpGained = _combat.calculateXpGained();
    
    await PostgresService().updatePlayerStats(
      widget.player.id,
      xpGained,
      isVictory ? 1 : 0,
      _combat.maxCombo,
    );
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(isVictory ? Icons.emoji_events : Icons.sentiment_very_dissatisfied,
                color: isVictory ? Colors.gold : Colors.grey),
            const SizedBox(width: 10),
            Text(isVictory ? 'VICTORE!' : 'DÉFAITE...'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildResultStat('Combo max', '${_combat.maxCombo}x', Icons.flash_on),
            const Divider(),
            _buildResultStat('XP gagnés', '+$xpGained', Icons.star),
            const Divider(),
            _buildResultStat('Niveau', '${widget.player.currentLevel}', Icons.trending_up),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _combat.reset();
                widget.player.totalXp += xpGained;
                _isAITurn = false;
              });
            },
            child: const Text('NOUVEAU COMBAT', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('QUITTER'),
          ),
        ],
      ),
    );
  }
  
  Widget _buildResultStat(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: Colors.grey),
              const SizedBox(width: 8),
              Text(label),
            ],
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('⚔️ ${widget.player.username} ⚔️'),
        backgroundColor: Colors.red,
        elevation: 0,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    const Icon(Icons.energy_savings_leaf, size: 16),
                    const SizedBox(width: 4),
                    Text('Niv.${widget.player.currentLevel}'),
                    const SizedBox(width: 12),
                    const Icon(Icons.star, size: 16),
                    const SizedBox(width: 4),
                    Text('${widget.player.totalXp} XP'),
                  ],
                ),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: widget.player.xpProgress / 1000,
                  backgroundColor: Colors.grey[800],
                  valueColor: const AlwaysStoppedAnimation(Colors.yellow),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Stats du joueur
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            color: Colors.grey[900],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatCard('💪 Force', _playerStats['strength'] ?? 10, Colors.red),
                _buildStatCard('⚡ Agilité', _playerStats['agility'] ?? 10, Colors.green),
                _buildStatCard('🎯 Technique', _playerStats['technique'] ?? 10, Colors.blue),
              ],
            ),
          ),
          
          // Zone de combat
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.grey[800],
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(widget.player.username, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                        Stickman(
                          isPlayer: true,
                          health: _combat.playerHealth,
                          animation: _playerAnimation,
                          color: Colors.blue,
                        ),
                        const SizedBox(height: 10),
                        HealthBar(health: _combat.playerHealth, maxHealth: 100),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('VS', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 24)),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('ADVERSAIRE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                        Stickman(
                          isPlayer: false,
                          health: _combat.opponentHealth,
                          animation: _opponentAnimation,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 10),
                        HealthBar(health: _combat.opponentHealth, maxHealth: 100),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Logs de combat
          Container(
            height: 120,
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey),
            ),
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('📜 HISTORIQUE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: ListView.builder(
                    reverse: true,
                    itemCount: _combat.combatLog.length,
                    itemBuilder: (context, index) {
                      final log = _combat.combatLog.reversed.toList()[index];
                      final isPlayer = log['turn'] == 'player';
                      return ListTile(
                        dense: true,
                        leading: Icon(isPlayer ? Icons.person : Icons.android, color: isPlayer ? Colors.green : Colors.red, size: 20),
                        title: Text(
                          log['dodged'] == true 
                              ? 'ESQUIVE!' 
                              : '${log['move']} : ${log['damage']} dégâts',
                          style: TextStyle(
                            color: isPlayer ? Colors.green : Colors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        trailing: log['combo'] > 0 
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.orange,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text('x${log['combo']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                              )
                            : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          
          // Contrôles
          CombatControls(
            onMoveSelected: _performMove,
            unlockedSkills: _unlockedSkills,
          ),
        ],
      ),
    );
  }
  
  Widget _buildStatCard(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.white)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(value.toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

// Extension pour convertir les données
extension PlayerFromJson on Player {
  static Player fromJson(Map<String, dynamic> json) {
    return Player(
      id: json['id'],
      username: json['username'],
      totalXp: json['total_xp'],
      currentLevel: json['current_level'],
      totalWins: json['total_wins'],
      totalGames: json['total_games_played'],
    );
  }
}